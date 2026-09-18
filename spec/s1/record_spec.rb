# frozen_string_literal: true

RSpec.describe S1::Measurable do
  let(:firm) { Firm.create!(name: "Dudley", preferences: { "sol_years" => 2 }) }
  let(:call) { PhoneCall.create!(firm: firm, transcript: "I need a lawyer, I was rear-ended yesterday") }

  describe "forms" do
    it "registers named forms and a default" do
      expect(PhoneCall.s1_states).to eq(%i[default review window])
    end

    it "builds the default form" do
      expect(call.s1_state).to eq(transcript: call.transcript)
    end

    it "takes arguments" do
      expect(call.s1_state(:window, last: 9)).to eq(transcript: "yesterday")
    end

    it "falls back to attributes when nothing is declared" do
      expect(firm.s1_state).to eq(firm.attributes)
    end

    it "raises on an unknown form" do
      expect { call.as(:nope) }.to raise_error(ArgumentError, /no s1_state :nope/)
    end

    it "inherits forms" do
      klass = Class.new(PhoneCall) { s1_state(:short) { { transcript: transcript[0, 6] } } }
      expect(klass.s1_states).to eq(%i[default review window short])
      expect(PhoneCall.s1_states).not_to include(:short)
    end
  end

  describe "#as" do
    it "is a Subject over the rendered form, tagged with owner and form" do
      subject = call.as(:review)
      expect(subject).to be_a(S1::Subject)
      expect(subject.state).to eq(transcript: call.transcript, firm: firm.attributes)
      expect(subject.options).to eq(owner: call, form: :review)
    end

    it "does not recurse when two forms reference each other (item ↔ claims)" do
      firm_class = Class.new(Firm) do
        has_many :cycle_calls, foreign_key: :firm_id, class_name: "CycleCall"
        measurable_as do
          { name: name, calls: cycle_calls.to_a }
        end
      end
      call_class = Class.new(PhoneCall) do
        belongs_to :cycle_firm, foreign_key: :firm_id, class_name: "CycleFirm"
        measurable_as do
          { transcript: transcript, firm: cycle_firm }
        end
      end
      stub_const("CycleFirm", firm_class)
      stub_const("CycleCall", call_class)
      f = firm_class.find(firm.id)
      f.cycle_calls.create!(transcript: "a")
      state = nil
      expect { state = f.as_measurable.state }.not_to raise_error # a SystemStackError otherwise
      expect(state[:calls].first[:transcript]).to eq("a")
      expect(state[:calls].first[:firm]).to eq(f.attributes) # the cycle closes on attributes
    end

    it "renders a record met inside its own form as attributes, not recursion" do
      klass = Class.new(PhoneCall) { measurable_as(:selfie) { { me: self, transcript: transcript } } }
      state = klass.find(call.id).as_measurable(:selfie).state
      expect(state[:me]).to eq(call.attributes)
      expect(state[:transcript]).to eq(call.transcript)
    end

    it "renders nested Measurable records through their default form" do
      Firm.s1_state { { name: name } }
      expect(call.as(:review).state[:firm]).to eq(name: "Dudley")
    ensure
      Firm.s1_states.delete(:default)
      Firm.remove_method(:s1_state_default)
    end
  end

  describe "primitives on the record" do
    before { stub_s1(noul: 0.9, choice: :mva, score: 2) }

    it "delegates to the default form" do
      expect(call.noul?("Is this a lead?")).to be(true)
      expect(call.ask?("Is this a lead?")).to be(true)
      expect(call.judge?("Is this a lead?")).to be(true)
      expect(call.judge("Is this a lead?")).to be >= 0.9
      expect(call.batch { |q| q.noul :lead, "Lead?" }.true?(:lead)).to be(true)
      expect(call.is?("a lead")).to be(true)
      expect(S1.to_state(call)).to be_a(S1::Measurable::Subject)
      expect(S1.to_state(call, as: :window, last: 9).state).to eq(transcript: "yesterday")
      expect(call.noul("Is this a lead?")).to be >= 0.9
      expect(call.choose("Type?", mva: "car", slip: "fall")).to be_a(S1::Answer::Choice)
      expect(call.score("Quality?", "D", "C", "B", "A")).to be_a(S1::Answer::Score)
    end

    it "the verb measures, the noun collapses" do
      expect(call.judge("Is this a lead?")).to be_a(S1::Answer::Noul)
      expect(call.judge?("Is this a lead?")).to be(true)
      expect(call.judge?("Is this a lead?")).to eq(call.judge("Is this a lead?").collapse)
      expect(call.choice("Type?", mva: "car", slip: "fall")).to eq(:mva)
      expect(call.choice("Type?", mva: "car", slip: "fall")).to eq(call.choose("Type?", mva: "car", slip: "fall").collapse)
      expect(call.level("Quality?", "D", "C", "B", "A")).to eq("B")
      expect(call.level("Quality?", "D", "C", "B", "A")).to be_a(S1::Level)
      expect(call.level("Quality?", "D", "C", "B", "A")).to eq(call.score("Quality?", "D", "C", "B", "A").collapse)
    end

    it "works through predicates, with as: picking the form" do
      seen = nil
      stub_s1 { |req| seen = req.state and { noul: 0.9, choice: :mva } }
      expect([call].select(&S1.predicates.is("x", as: :window))).to eq([call])
      expect(seen[:transcript].length).to eq(20)
      expect([call].group_by(&S1.predicates.choose("Type?", mva: "car", slip: "fall")).keys).to eq([:mva])
    end

    it "applies a predicate's given: over a Measurable record's declared lens" do
      klass = stub_const("Lensed2", Class.new(PhoneCall) do
        measurable_as { { t: transcript } }
        measured_against { { policy: "p", carrier: "c" } }
      end)
      seen = nil
      stub_s1 { |req| seen = req.state and { noul: 0.9 } }
      expect([klass.find(call.id)].select(&S1.predicates.is("x", given: { policy: "strict" }))).not_to be_empty
      expect(seen).to eq(this: { t: call.transcript }, policy: "strict", carrier: "c")
    end

    it "passes the state through to the provider" do
      seen = nil
      stub_s1 { |req| seen = req.state and {} }
      call.as(:window, last: 9).noul?("q?")
      expect(seen).to eq(transcript: "yesterday")
    end
  end

  describe "#update_ask" do
    before { stub_s1(is_lead: 0.9, lead_probability: 0.9, case_type: :mva, quality: 2, quality_position: 2, quality_level: 2, extra: 0.7) }

    def questions(q)
      q.noul   :is_lead,          "Is this a lead?"
      q.noul   :lead_probability, "Is this a lead?"
      q.choice :case_type,        "Type?", mva: "car", slip: "fall"
      q.score  :quality,          "Quality?", "D", "C", "B", "A"
      q.score  :quality_position, "Quality?", "D", "C", "B", "A"
      q.score  :quality_level,    "Quality?", "D", "C", "B", "A"
      q.noul   :extra,            "Speculative, not a column"
    end

    it "writes answers to columns, coerced by column type" do
      result = call.update_ask { |q| questions(q) }
      call.reload
      expect(call.is_lead).to be(true)
      expect(call.lead_probability).to eq(0.9)
      expect(call.case_type).to eq("mva")
      expect(call.quality).to eq(2)
      expect(call.quality_position).to eq(2.0)
      expect(call.quality_level).to eq("B")
      expect(result[:extra].to_f).to eq(0.7)
      expect(call).not_to respond_to(:extra)
    end

    it "thresholds booleans with the state's threshold" do
      S1.config.threshold = 0.95
      call.update_ask { |q| q.noul :is_lead, "Lead?" }
      expect(call.reload.is_lead).to be(false)
    end

    it "keeps raw answers in s1_answers when the column exists" do
      call.update_ask(as: :review) { |q| q.noul :is_lead, "Lead?" }
      audit = call.reload.s1_answers.fetch("is_lead")
      expect(audit).to include("type" => "noul", "value" => "0.9", "form" => "review", "model" => "stub")
      expect(audit["probabilities"]["true"]).to eq(0.9)

      call.update_ask { |q| q.choice :case_type, "Type?", mva: "car", slip: "fall" }
      expect(call.reload.s1_answers.keys).to contain_exactly("is_lead", "case_type")
    end

    it "yields the record to the block" do
      seen = nil
      call.update_ask { |q, record| seen = record and q.noul :is_lead, "Lead?" }
      expect(seen).to eq(call)
    end

    it "works on a model with no declared form" do
      legacy = LegacyCall.create!(transcript: "hi")
      legacy.update_ask { |q| q.noul :is_lead, "Lead?" }
      expect(legacy.reload.is_lead).to be(true)
    end

    it "runs validations" do
      allow(call).to receive(:valid?).and_return(false)
      expect { call.update_ask { |q| q.noul :is_lead, "Lead?" } }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "#assign_ask" do
    before { stub_s1(case_type: :mva, extra: 0.7) }

    it "assigns without saving" do
      result = call.assign_ask { |q| q.choice(:case_type, "Type?", mva: "car", slip: "fall") and q.noul(:extra, "x?") }
      expect(call.case_type).to eq("mva")
      expect(call).to have_changes_to_save
      expect(call.reload.case_type).to be_nil
      expect(result[:extra].to_f).to eq(0.7)
    end

    it "enriches from a before_save, on create and on relevant change only" do
      asked = []
      stub_s1 { |req| asked << req.state[:transcript] and { case_type: req.state[:transcript].include?("fell") ? :slip : :mva } }

      triaged = TriagedCall.create!(transcript: "I fell in the store")
      expect(triaged.reload.case_type).to eq("slip")
      triaged.update!(legacy_score: 3)
      triaged.update!(transcript: "I was rear-ended")
      expect(triaged.reload.case_type).to eq("mva")
      expect(asked).to eq(["I fell in the store", "I was rear-ended"])
    end
  end

  describe ".update_ask_all" do
    before { firm }

    let!(:calls) { 5.times.map { |i| PhoneCall.create!(firm: firm, transcript: "call #{i}") } }

    it "updates every record in the relation, one ask per record" do
      asked = Queue.new
      stub_s1 { |req| asked << req.state[:transcript] and { is_lead: req.state[:transcript].end_with?("3") ? 0.9 : 0.1 } }

      results = PhoneCall.where("transcript LIKE ?", "call %").update_ask_all(concurrency: 3) do |q, record|
        q.noul :is_lead, "Lead? #{record.id}"
      end

      expect(results.keys).to match_array(calls)
      expect(results.values).to all(be_a(S1::Result))
      expect(asked.size).to eq(5)
      expect(PhoneCall.where(is_lead: true).pluck(:transcript)).to eq(["call 3"])
    end

    it "runs asks concurrently" do
      stub_s1 do |_|
        sleep 0.1
        { is_lead: 0.9 }
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      PhoneCall.all.update_ask_all(concurrency: 5) { |q| q.noul :is_lead, "Lead?" }
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.3
    end

    it "honours the form and scoping" do
      stub_s1(is_lead: 0.9)
      PhoneCall.where(id: calls.first).update_ask_all(as: :review) { |q| q.noul :is_lead, "Lead?" }
      expect(PhoneCall.where(is_lead: true).count).to eq(1)
      expect(calls.first.reload.s1_answers.dig("is_lead", "form")).to eq("review")
    end
  end

  describe ".measure_all" do
    before { firm }

    let!(:calls) { 3.times.map { |i| PhoneCall.create!(firm: firm, transcript: "call #{i}") } }

    it "measures every record and writes nothing" do
      stub_s1(is_lead: 0.9)
      results = PhoneCall.all.measure_all(concurrency: 3) { |q, record| q.judge :is_lead, "Lead? #{record.id}" }
      expect(results.keys).to match_array(calls)
      expect(results.values.map { |r| r[:is_lead].to_f }).to all(eq(0.9))
      expect(PhoneCall.where(is_lead: true).count).to eq(0)
      expect(PhoneCall.all.ask_all { |q| q.judge :is_lead, "Lead?" }.size).to eq(3)
    end
  end

  describe ".where_judged / .where_judged_not" do
    it "keeps the Enumerable and s1_ spellings" do
      expect(PhoneCall.method(:measure_select)).to eq(PhoneCall.method(:where_judged))
      expect(PhoneCall.method(:s1_reject)).to eq(PhoneCall.method(:where_judged_not))
    end

    before { firm }

    let!(:calls) { 3.times.map { |i| PhoneCall.create!(firm: firm, transcript: "call #{i}") } }

    it "partitions the relation by a noul, one call per record" do
      stub_s1 { |req| { noul: req.state[:transcript].end_with?("1") ? 0.9 : 0.1 } }
      expect(PhoneCall.all.where_judged("Odd one?", concurrency: 3)).to eq([calls[1]])
      expect(PhoneCall.all.where_judged_not("Odd one?")).to eq([calls[0], calls[2]])
    end

    it "judges each record against given: context, and finds the records that are the same as a text" do
      stub_s1 { |req| { noul: req.state.is_a?(Hash) && req.state[:this].to_s.include?("1") && req.state[:other].to_s.include?("1") ? 0.9 : 0.1 } }
      expect(PhoneCall.all.where_same_as("call 1", concurrency: 3)).to eq([calls[1]])
      expect(PhoneCall.all.measure_grep("call 1")).to eq([calls[1]])
      stub_s1 { |req| { noul: req.state[:text].to_s.include?(req.state[:this][:transcript].to_s[-1]) ? 0.9 : 0.1 } }
      expect(PhoneCall.all.where_judged("Is `this` the call in `text`?", given: { text: "about call 2" })).to eq([calls[2]])
    end

    it "has where_is / where_is_not, the relation's is?" do
      asked = nil
      stub_s1 { |req| asked = req.questions[:noul].instructions and { noul: 0.9 } }
      expect(PhoneCall.where(id: calls.first).where_is("a lead")).to eq([calls.first])
      expect(asked).to eq("Is this a lead?")
      expect(PhoneCall.where(id: calls.first).where_is_not("a lead")).to eq([])
    end

    it "takes a threshold and honours scoping" do
      stub_s1(noul: 0.8)
      expect(PhoneCall.where(id: calls.first).where_judged("q?", threshold: 0.9)).to eq([])
      expect(PhoneCall.where(id: calls.first).where_judged("q?", threshold: 0.7)).to eq([calls.first])
    end
  end

  describe "caching" do
    let(:asks) { [] }

    before do
      S1.config.cache = ActiveSupport::Cache::MemoryStore.new
      stub_s1 { |req| asks << req.state and { noul: 0.9, is_lead: 0.9 } }
    end

    it "asks once per record version, form, args and questions" do
      3.times { call.noul?("Lead?") }
      call.as(:window, last: 9).noul?("Lead?")
      call.as(:window, last: 3).noul?("Lead?")
      call.noul?("Other?")
      expect(asks.size).to eq(4)
    end

    it "is bypassed by a write, since update_ask bumps the version" do
      call.update_ask { |q| q.noul :is_lead, "Lead?" }
      call.update_ask { |q| q.noul :is_lead, "Lead?" }
      expect(asks.size).to eq(2)
    end

    it "keys on the lens too" do
      call.given(policy: "a").judge?("q?")
      call.given(policy: "b").judge?("q?")
      call.given(policy: "a").judge?("q?")
      expect(asks.size).to eq(2)
    end

    it "is bypassed for new and dirty records" do
      fresh = PhoneCall.new(firm: firm, transcript: "a")
      fresh.noul?("Lead?")
      PhoneCall.new(firm: firm, transcript: "b").noul?("Lead?")
      call.noul?("Lead?")
      call.transcript = "edited"
      call.noul?("Lead?")
      expect(asks.size).to eq(4)
    end

    it "is off without a configured cache" do
      S1.config.cache = nil
      2.times { call.noul?("Lead?") }
      expect(asks.size).to eq(2)
    end
  end
end
