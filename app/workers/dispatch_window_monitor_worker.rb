# frozen_string_literal: true

class DispatchWindowMonitorWorker
  DISPATCH_WINDOW_INTERVAL_SEC = ENV['DISPATCH_WINDOW_SECOND']&.to_i || 3

  def perform
    Rails.logger.info('DispatchWindowMonitorWorker.perform - START')

    Thread.abort_on_exception = true

    redis = RedisHelper.create_new_client

    redis.psubscribe('order:*:request') do |on|
      on.pmessage do |_, channel, msg|
        if msg == 'start_lottery'
          order_id = channel.split(':')&.at(1)

          return if order_id.blank?

          create_dispatch_window_subscription_thread(order_id)
        end
      end
    end
  ensure
    Rails.logger.info('DispatchWindowMonitorWorker.perform - END')
  end

  private

  def create_dispatch_window_subscription_thread(order_id)
    Thread.new(order_id, DISPATCH_WINDOW_INTERVAL_SEC) do |order_id, dispatch_window_interval|
      Rails.logger.info("DispatchWindowMonitorWorker.create_dispatch_window_subscription_thread - START, order_id: #{order_id}")
      redis = RedisHelper.create_new_client

      drivers = []
      start_time = Time.current

      redis.without_reconnect do
        redis.subscribe_with_timeout(dispatch_window_interval, "order:#{order_id}:request") do |on|
          on.message do |_, msg|
            driver_id = parse_driver_id(msg)
            drivers.push(driver_id) if driver_id
          end
        end
      rescue Redis::TimeoutError
        # this is expected, do nothing
      end

      Rails.logger.info("DispatchWindowMonitorWorker.create_dispatch_window_subscription_thread - order_id: #{order_id}, subscribe time: #{(Time.current - start_time).to_f}s")
      Rails.logger.info("DispatchWindowMonitorWorker.create_dispatch_window_subscription_thread - order_id: #{order_id}, no of drivers participated: #{drivers.size}")

      if drivers.any?
        winner_id = DispatchWindowWinnerPickerService.pick(drivers)
        Rails.logger.info("DispatchWindowMonitorWorker.create_dispatch_window_subscription_thread - order_id: #{order_id}, winner: #{winner_id}")
        redis.publish("order:#{order_id}:request", { winner_id: winner_id, no_of_drivers: drivers.size }.to_json)
      end
    rescue StandardError => e
      Rails.logger.error e.message
      Rails.logger.error e.backtrace.join("\n")
    ensure
      Rails.logger.info("DispatchWindowMonitorWorker.create_dispatch_window_subscription_thread - END, order_id: #{order_id}")
      redis.close
    end
  end

  def parse_driver_id(raw_msg)
    JSON.parse(raw_msg)&.fetch('driver_id', nil)
  rescue JSON::ParserError => e
    Rails.logger.error "DispatchWindowMonitorWorker.parse_driver_id - failed to parse #{raw_msg}"
  end
end
