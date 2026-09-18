# frozen_string_literal: true

require "rails"
require "s1/railtie"

RSpec.describe S1::Railtie do
  before(:all) do
    app = Class.new(Rails::Application) do
      config.eager_load = false
      config.logger = Logger.new(nil)
      config.active_support.to_time_preserves_timezone = :zone
    end
    app.initialize!
  end

  # The suite resets config per example, so re-apply what the boot initializer did.
  before do
    described_class.initializers.each { |i| i.run(Rails.application) }
    S1.config.provider = S1::Providers::Stub.new(noul: 0.9)
  end

  it "defaults the logger and a fiber-safe context" do
    expect(S1.config.logger).to eq(Rails.logger)
    expect(S1.config.context).to eq(ActiveSupport::IsolatedExecutionState)
    S1.about("x") { expect(ActiveSupport::IsolatedExecutionState[:s1_subject].state).to eq("x") }
  end

  it "instruments every call as ask.s1" do
    events = []
    ActiveSupport::Notifications.subscribed(->(event) { events << event.payload }, "ask.s1") do
      S1::Subject.new("x", owner: :me).noul?("q?")
    end
    expect(events.size).to eq(1)
    expect(events.first[:request].options[:owner]).to eq(:me)
    expect(events.first[:result].model).to eq("stub")
  end
end
