# frozen_string_literal: true

RSpec.describe S1::AskJob do
  let(:firm) { Firm.create!(name: "Dudley") }
  let(:call) { PhoneCall.create!(firm: firm, transcript: "I was rear-ended yesterday") }

  before { stub_s1(is_lead: 0.9, case_type: :mva) }

  it "enqueues the built questions and applies them on perform" do
    seen = nil
    stub_s1 { |req| seen = req and { is_lead: 0.9, case_type: :mva } }

    call.update_ask_later(as: :window, last: 9) do |q, record|
      q.noul   :is_lead,   "Lead? (#{record.id})", true: "a new matter"
      q.choice :case_type, "Type?", mva: "car", slip: "fall"
    end
    expect(enqueued_jobs.map { |j| j["job_class"] }).to eq(["S1::AskJob"])
    expect(call.reload.is_lead).to be_nil

    perform_enqueued_jobs
    call.reload
    expect(call.is_lead).to be(true)
    expect(call.case_type).to eq("mva")
    expect(seen.state).to eq(transcript: "yesterday")
    expect(seen.questions[:is_lead].instructions).to eq("Lead? (#{call.id})")
    expect(seen.questions[:is_lead].criteria).to eq("true" => "a new matter")
    expect(seen.options[:form]).to eq(:window)
  end

  it "retries transient errors" do
    expect(described_class.rescue_handlers.map(&:first)).to include("S1::TransientError")
  end
end
