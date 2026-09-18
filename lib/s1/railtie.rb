# frozen_string_literal: true

module S1
  # Rails defaults, applied before config/initializers so an initializer can
  # still override them:
  #   - logger: Rails.logger
  #   - context: fiber-safe ambient subject (ActiveSupport::IsolatedExecutionState)
  #   - every completed call emits "ask.s1" (payload: result, request) for
  #     cost ledgers and telemetry:
  #       ActiveSupport::Notifications.subscribe("ask.s1") do |event|
  #         result, request = event.payload.values_at(:result, :request)
  #         Ledger.record(owner: request.options[:owner], model: result.model, **result.usage)
  #       end
  class Railtie < ::Rails::Railtie
    initializer "s1.defaults", before: :load_config_initializers do
      S1.config.logger ||= ::Rails.logger
      S1.config.context ||= ActiveSupport::IsolatedExecutionState
      S1.on_result do |result, request|
        ActiveSupport::Notifications.instrument("ask.s1", result: result, request: request)
      end
    end

    # Measured fields vs the schema, once the models are loaded (eager_load: production).
    config.after_initialize do |app|
      S1::Measurable.verify! if app.config.eager_load
    end
  end
end
