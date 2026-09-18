# frozen_string_literal: true

require "active_record"
require "s1-rails"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :firms do |t|
    t.string :name
    t.json :preferences
  end
  create_table :deliveries do |t|
    t.string :status
    t.integer :priority
    t.string :note
    t.boolean :note_needed
    t.integer :priority_score
    t.timestamps
  end
  create_table :replies do |t|
    t.text :body
    t.text :note
  end
  create_table :phone_calls do |t|
    t.references :firm
    t.text :transcript
    t.boolean :is_lead
    t.float :lead_probability
    t.string :case_type
    t.integer :quality
    t.float :quality_position
    t.string :quality_level
    t.json :s1_answers
    t.integer :legacy_score
    t.timestamps
  end
end

class Firm < ActiveRecord::Base
  include S1::Measurable

  has_many :phone_calls
end

class PhoneCall < ActiveRecord::Base
  include S1::Measurable

  belongs_to :firm

  s1_state { { transcript: transcript } }
  s1_state(:review) { { transcript: transcript, firm: firm } }
  s1_state(:window) { |last: 20| { transcript: transcript.to_s[-last..] || transcript } }
end

class Delivery < ActiveRecord::Base
  include S1::Measurable

  measured_field :note_needed, "Does the delivery need a note?" # boolean column → judge
  measured_field :priority_score, "How urgent?", { "can wait" => 10, "today" => 20, "now" => 30 } # integer column → score, explicit indexes

  s1_state(:sms) { |body:| { message: body } }
  s1_enum :status, "What is the sender reporting?",
          delivered: "Handed over or left somewhere", attempted: "Tried, no one there", undeliverable: "Bad address"
  s1_enum :priority, values: [0, 1], low: "Can wait", high: "Same day", prefix: true
  enum :note, { fragile: "fragile", bulky: "bulky" }
end

class Reply < ActiveRecord::Base
  validates :body, noul: "Is `body` a coherent support request?"
  validates :note, noul: { with: "Does `note` ask us to write to a different address?", expect: false, threshold: 0.8 },
                   if: :will_save_change_to_note?
end

class TriagedCall < ActiveRecord::Base
  self.table_name = "phone_calls"
  include S1::Measurable

  s1_state { { transcript: transcript } }

  before_save -> { assign_ask { |q| q.choice :case_type, "Type?", mva: "car", slip: "fall" } }, if: :will_save_change_to_transcript?
end

class LegacyCall < ActiveRecord::Base
  self.table_name = "phone_calls"
  include S1::Measurable
end

# Rails wires GlobalID for ActiveRecord in its railtie; the bare suite does it here.
GlobalID.app = "s1-rails-spec"
ActiveRecord::Base.include(GlobalID::Identification)
ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(nil)

RSpec.configure do |config|
  config.include ActiveJob::TestHelper
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }

  config.before do
    clear_enqueued_jobs
    S1.reset_config!
    S1.clear_hooks!
    PhoneCall.delete_all
    Reply.delete_all
    Firm.delete_all
  end
end

def stub_s1(answers = {}, &)
  S1.config.provider = S1::Providers::Stub.new(answers, &)
end
