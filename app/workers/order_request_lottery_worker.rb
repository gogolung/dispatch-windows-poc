# frozen_string_literal: true

class OrderRequestLotteryWorker
  include Sidekiq::Worker
  LOTTERY_INTERVAL_SEC = ENV['DISPATCH_WINDOW_SECOND']&.to_i || 10

  def perform
    Rails.logger.info('OrderRequestLotteryWorker.perform - START')

    Thread.abort_on_exception = true

    redis = NEW_REDIS_CLIENT

    redis.psubscribe('order:*:request') do |on|
      on.pmessage do |_, channel, msg|
        if msg == 'start_lottery'
          order_id = channel.split(':')&.at(1)&.to_i

          return if order_id.blank? || order_id <= 0

          create_lottery_subscription_thread(order_id)
        end
      end
    end
  ensure
    Rails.logger.info('OrderRequestLotteryWorker.perform - END')
  end

  private

  def create_lottery_subscription_thread(order_id)
    Thread.new(order_id, LOTTERY_INTERVAL_SEC) do |order_id, lottery_interval|
      Rails.logger.info("OrderRequestLotteryWorker.create_lottery_subscription_thread - START, order_id: #{order_id}")
      redis = NEW_REDIS_CLIENT

      drivers = []
      start_time = Time.current

      redis.without_reconnect do
        redis.subscribe_with_timeout(lottery_interval, "order:#{order_id}:request") do |on|
          on.message do |_, msg|
            driver_id = parse_driver_id(msg)
            drivers.push(driver_id) if driver_id
          end
        end
      rescue Redis::TimeoutError
        # this is expected, do nothing
      end

      Rails.logger.info("OrderRequestLotteryWorker.create_lottery_subscription_thread - order_id: #{order_id}, subscribe time: #{(Time.current - start_time).to_f}s")
      Rails.logger.info("OrderRequestLotteryWorker.create_lottery_subscription_thread - order_id: #{order_id}, drivers participated: #{drivers.as_json}")

      if drivers.any?
        winner_id = OrderRequestLotteryService.draw(drivers)
        Rails.logger.info("OrderRequestLotteryWorker.create_lottery_subscription_thread - order_id: #{order_id}, winner: #{winner_id}")
        redis.publish("order:#{order_id}:request", { winner_id: winner_id }.to_json)
      end
    ensure
      Rails.logger.info("OrderRequestLotteryWorker.create_lottery_subscription_thread - END, order_id: #{order_id}")
    end
  end

  def parse_driver_id(raw_msg)
    JSON.parse(raw_msg)&.fetch('driver_id', nil)
  rescue JSON::ParserError => e
    Rails.logger.error "OrderRequestLotteryWorker.parse_driver_id - failed to parse #{raw_msg}"
  end
end
