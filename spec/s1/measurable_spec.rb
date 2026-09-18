# frozen_string_literal: true

RSpec.describe "the theory's names on records" do
  let(:delivery) { Delivery.create!(status: :attempted) }

  it "declares forms with measurable_as and reaches them with as_measurable" do
    expect(Delivery.method(:measurable_as)).to eq(Delivery.method(:s1_state))
    expect(delivery.as_measurable(:sms, body: "x").state).to eq(message: "x")
  end

  it "aliases the ask verbs as measure verbs" do
    %i[update_measure assign_measure update_measure_later measure batch].each { |m| expect(delivery).to respond_to(m) }
    expect(Delivery).to respond_to(:update_measure_all)
    expect(Delivery.method(:measured_attribute)).to eq(Delivery.method(:measured_field))
  end

  it "judges against context with given / against" do
    seen = nil
    stub_s1 { |req| seen = req.state and { noul: 0.9 } }
    expect(delivery.against(policy: "same day").is?("on time per `policy`")).to be(true)
    expect(seen[:policy]).to eq("same day")
    expect(seen[:this]).to be_a(Hash)
  end

  describe "s1_field: the column decides the kind" do
    before { stub_s1 { |req| seen << req.questions and { note_needed: 0.9, priority_score: 2, status: :delivered } } }

    let(:seen) { [] }

    it "infers judge / score / choose from the column and the declaration" do
      expect(Delivery.s1_kind(:note_needed)).to eq(:noul)
      expect(Delivery.s1_kind(:priority_score)).to eq(:score)
      expect(Delivery.s1_kind(:status)).to eq(:choice)
      expect { Delivery.s1_kind(:created_at) }.to raise_error(ArgumentError, /cannot tell/)
    end

    it "lets a column name stand for its question in every verb, without writing" do
      expect(delivery.choose(:status)).to be_a(S1::Answer::Choice)
      expect(delivery.choose(:status).to_sym).to eq(:delivered)
      expect(delivery.judge(:note_needed).to_f).to eq(0.9)
      expect(delivery.judge?(:note_needed)).to be(true)
      expect(delivery.judge?(:note_needed, threshold: 0.95)).to be(false)
      expect(delivery.score(:priority_score).index).to eq(2)
      expect(delivery.measure(:note_needed, :status).answers.keys).to eq(%i[note_needed status])
      expect(delivery.reload.status).to eq("attempted") # measured, nothing written
      expect(delivery.note_needed).to be_nil
    end

    it "update_measure_later(:columns) serializes each column's own question" do
      delivery.update_measure_later(:note_needed, :status, as: :sms, body: "late")
      perform_enqueued_jobs
      expect(seen.last.keys).to eq(%i[note_needed status])
      expect(delivery.reload.note_needed).to be(true)
    end

    it "update_measure(:columns) asks each column's own question and writes the collapse" do
      delivery.update_measure(:note_needed, :priority_score, :status, as: :sms, body: "late")
      q = seen.last
      expect(q[:note_needed]).to be_a(S1::Question::Noul)
      expect(q[:note_needed].instructions).to eq("Does the delivery need a note?")
      expect(q[:priority_score]).to be_a(S1::Question::Score)
      expect(q[:priority_score].levels).to eq(["can wait", "today", "now"])
      expect(q[:status]).to be_a(S1::Question::Choice)
      delivery.reload
      expect(delivery.note_needed).to be(true)
      expect(delivery.priority_score).to eq(30) # the declared index for "now", not its position
      expect(delivery).to be_delivered
    end

    it "stores a score's collapse by the column: the label's text on a string column, the index on an integer one" do
      klass = Class.new(PhoneCall) do
        measured_field :quality_level, "Quality?", "D", "C", "B", "A"
        measured_field :quality, "Quality?", { "D" => 0, "C" => 1, "B" => 2, "A" => 3 }
      end
      stub_s1(quality_level: 2, quality: 2)
      call = klass.create!(firm: Firm.create!(name: "f"), transcript: "hi")
      expect(call.level(:quality_level)).to be_a(S1::Level)
      call.update_measure(:quality_level, :quality)
      expect(call.quality_level).to eq("B")
      expect(call.quality_level).to be_an_instance_of(String)
      call.reload
      expect(call.quality_level).to eq("B")
      expect(call.quality_level).to be_an_instance_of(String)
      expect(call.quality).to eq(2)
    end
  end

  describe "declarations vs schema" do
    it "verifies every Measurable model at once" do
      expect(S1::Measurable.models).to include(Delivery, PhoneCall)
      expect(S1::Measurable.verify!).to include(Delivery)
    end

    it "raises when a measured field is not a column" do
      klass = Class.new(Delivery) { measured_field :ghost, "Is it there?" }
      expect { klass.s1_verify_fields! }.to raise_error(ArgumentError, /ghost.*not a column/)
    end

    it "raises when the kind does not fit the column" do
      klass = # a score on a string enum column: choice wins, levels are noise
        Class.new(Delivery) do
          measured_field :note, "How much?", "a", "b"
        end
      expect(klass.s1_kind(:note)).to eq(:choice)
      klass2 = Class.new(Delivery) { measured_field :note_needed, "Which?", a: "1", b: "2" } # options on a boolean column
      expect { klass2.s1_verify_fields! }.to raise_error(ArgumentError, /measured as choice but its column is boolean/)
    end

    it "keeps stored scores meaning the same thing when a level is inserted — the foot-gun, closed" do
      v1 = Class.new(Delivery) { measured_field :priority_score, "How urgent?", { "can wait" => 10, "today" => 20, "now" => 30 } }
      stub_s1(priority_score: 1) # the model picks the second level: "today"
      row = v1.create!(status: :attempted)
      row.update_measure(:priority_score, as: :sms, body: "x")
      expect(row.reload.priority_score).to eq(20)

      # A release later, a level is inserted in the middle. With explicit indexes the old
      # row still means "today"; the new level takes a new integer.
      v2 = Class.new(Delivery) { measured_field :priority_score, "How urgent?", { "can wait" => 10, "this week" => 15, "today" => 20, "now" => 30 } }
      expect(v2.s1_fields[:priority_score][:levels]).to eq(["can wait", "this week", "today", "now"])
      expect(v2.find(row.id).priority_score).to eq(20)
      expect(v2.s1_fields[:priority_score][:levels][v2.s1_fields[:priority_score][:indexes].index(20)]).to eq("today")

      # With positional levels the same insertion would have silently re-labelled every stored 1 as "this week".
      positional = Class.new(Delivery) { measured_field :priority_score, "How urgent?", "can wait", "this week", "today", "now" }
      expect(positional.s1_fields[:priority_score][:levels][1]).to eq("this week")
    end

    it "stores a choice by name, so inserting an option is safe; positional enum values warn" do
      expect(Delivery.statuses).to eq("delivered" => "delivered", "attempted" => "attempted", "undeliverable" => "undeliverable")
      log = StringIO.new
      S1.config.logger = Logger.new(log)
      stub_const("Parcel2", Class.new(Delivery) { measured_enum :priority, "?", values: [0, 1], low: "l", high: "h" })
      expect(log.string).to include("positional values")
    end

    it "warns, loudly, about positional levels on an integer column" do
      log = StringIO.new
      S1.config.logger = Logger.new(log)
      klass = Class.new(Delivery) { measured_field :priority_score, "How urgent?", "can wait", "today", "now" }
      klass.s1_verify_fields!
      expect(log.string).to include("positional levels").and include("explicit indexes")
      expect do
        Class.new(Delivery) do
          measured_field :priority_score, "?", { "a" => 1, "b" => 1 }
        end
      end.to raise_error(ArgumentError, /distinct integers/)
    end
  end

  describe "measure_on:" do
    let(:seen) { [] }

    it "is nil by default: a declaration registers no callback and nothing measures on its own" do
      klass = stub_const("Parcel0", Class.new(Delivery) do
        measured_field :note_needed, "Note?"
        measured_enum :status, "Which?", delivered: "d", attempted: "a", undeliverable: "u"
      end)
      S1.config.provider = ->(_req) { raise "should not be called" }
      row = klass.create!(status: :attempted)
      row.update!(note: :bulky)
      perform_enqueued_jobs
      expect(klass.s1_triggers).to be_empty
      expect(row.reload.note_needed).to be_nil
      expect(row).to be_attempted
    end

    before { stub_s1 { |req| seen << req.questions.keys and { note_needed: 0.9, priority_score: 1, status: :delivered } } }

    it ":validation measures synchronously, before validation, fields grouped in one call" do
      klass = Class.new(Delivery) do
        measured_field :note_needed, "Note?", measure_on: :validation
        measured_field :priority_score, "Urgent?", { "a" => 10, "b" => 20 }, measure_on: :validation
      end
      row = klass.create!(status: :attempted)
      expect(row.note_needed).to be(true)
      expect(row.priority_score).to eq(20)
      expect(seen).to eq([%i[note_needed priority_score]]) # one call for both
    end

    it ":create / :save / :update enqueue after commit; if: passes through" do
      klass = stub_const("Parcel", Class.new(Delivery) do
        measured_enum :status, "Which?", delivered: "d", attempted: "a", undeliverable: "u", measure_on: :create
        measured_field :note_needed, "Note?", measure_on: :update, if: :saved_change_to_note?
      end)
      row = klass.create!(status: :attempted)
      expect(enqueued_jobs.size).to eq(1)
      perform_enqueued_jobs
      expect(row.reload).to be_delivered
      clear_enqueued_jobs
      row.update!(priority: :high)
      expect(enqueued_jobs).to be_empty
      row.update!(note: :bulky)
      expect(enqueued_jobs.size).to eq(1)
    end

    it "rejects an unknown trigger" do
      expect { Class.new(Delivery) { measured_field :note_needed, "?", measure_on: :whenever } }.to raise_error(ArgumentError, /measure_on/)
    end
  end

  describe "measured_against: the declared lens" do
    let(:seen) { [] }

    before { stub_s1 { |req| seen << req.state and { noul: 0.9, note_needed: 0.9, priority_score: 1, choice: :delivered } } }

    it "puts the facts under this and the lens beside them, on every verb, merged with given:" do
      klass = stub_const("Lensed", Class.new(Delivery) do
        measurable_as { { message: status } }
        measured_against { { policy: "same day", carrier: "royal mail" } }
        measured_field :note_needed, "Is `this` within `policy`?", measure_on: :validation
      end)
      row = klass.create!(status: :attempted) # measure_on used the lens
      expect(seen.last).to eq(this: { message: "attempted" }, policy: "same day", carrier: "royal mail")
      expect(row.note_needed).to be(true)

      row.is?("late per `policy`") # a plain verb: the lens is there
      expect(seen.last[:policy]).to eq("same day")

      row.update_measure(:priority_score, given: { policy: "next day" }) # per-call given: merges over it
      expect(seen[-2]).to include(policy: "next day", carrier: "royal mail") # (-1 is the :validation re-measure on save)

      row.given(policy: "whenever").choose("Which?", a: "1", b: "2")                # fluent, same merge
      expect(seen.last).to include(policy: "whenever", carrier: "royal mail")

      klass.where(id: row.id).measure_all(:note_needed, given: { rush: true })      # a relation, same axes
      expect(seen.last).to include(policy: "same day", rush: true)

      expect(klass.method(:measured_given)).to eq(klass.method(:measured_against))
    end

    it "carries given: into the job" do
      klass = stub_const("LensedLater", Class.new(Delivery) { measurable_as { { message: status } } })
      row = klass.create!(status: :attempted)
      row.update_measure_later(:note_needed, given: { policy: "same day" })
      perform_enqueued_jobs
      expect(seen.last).to eq(this: { message: "attempted" }, policy: "same day")
      expect(row.reload.note_needed).to be(true)
    end

    it "has no lens without a declaration: the facts alone" do
      delivery = Delivery.create!(status: :attempted)
      delivery.as_measurable(:sms, body: "x").is?("q?")
      expect(seen.last).to eq(message: "x")
    end
  end
end
