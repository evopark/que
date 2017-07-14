# frozen_string_literal: true

module Que
  class Listener
    MESSAGE_CALLBACKS = {
      new_job: -> (message) {
        message[:run_at] = Time.parse(message.fetch(:run_at))
      },
    }.freeze

    MESSAGE_FORMATS = {
      new_job: {
        queue:    String,
        id:       Integer,
        run_at:   Time,
        priority: Integer,
      },
    }.each_value(&:freeze).freeze

    def initialize(pool:)
      @pool = pool
    end

    def listen
      @pool.checkout do |conn|
        @pool.execute "LISTEN que_listener_#{conn.backend_pid}"
      end
    end

    def wait_for_messages(timeout)
      # Make sure we never pass nil to this method, so we don't hang the thread.
      Que.assert(Numeric, timeout)

      output = {}

      @pool.checkout do |conn|
        loop do
          notification_received =
            conn.wait_for_notify(timeout) do |_, _, payload|
              # We've received at least one notification, so zero out the
              # timeout before we loop again to retrieve the next message. This
              # ensures that we don't wait an additional `timeout` seconds after
              # processing the final message before this method returns.
              timeout = 0

              # Be very defensive about the message we receive - it may not be
              # valid JSON, and may not have a message_type key.
              messages =
                begin
                  Que.deserialize_json(payload)
                rescue JSON::ParserError
                end

              next unless messages

              unless messages.is_a?(Array)
                messages = [messages]
              end

              messages.each do |message|
                message_type = message && message.delete(:message_type)
                next unless message_type.is_a?(String)

                (output[message_type.to_sym] ||= []) << message
              end
            end

          break unless notification_received
        end
      end

      output.each do |type, messages|
        if callback = MESSAGE_CALLBACKS[type]
          messages.select! do |message|
            begin
              callback.call(message)
              true
            rescue => error
              Que.notify_error_async(error)
              false
            end
          end
        end

        if format = MESSAGE_FORMATS[type]
          messages.select! do |m|
            if message_matches_format?(m, format)
              true
            else
              message = [
                "Message of type '#{type}' doesn't match format!",
                "Message: #{m.inspect}",
                "Format: #{format.inspect}",
              ].join("\n")

              Que.notify_error_async(Error.new(message))
              false
            end
          end
        end

        messages.each(&:freeze)
      end

      output.delete_if { |_, messages| messages.empty? }

      if output.any?
        Que.internal_log(:messages_received) do
          {
            messages: output,
          }
        end
      end

      output
    end

    def unlisten
      @pool.checkout do |conn|
        # Unlisten and drain notifications before releasing the connection.
        @pool.execute "UNLISTEN *"
        {} while conn.notifies
      end
    end

    private

    def message_matches_format?(message, format)
      return false unless message.length == format.length

      format.all? do |key, type|
        value = message.fetch(key) { return false }
        Que.assert?(type, value)
      end
    end
  end
end
