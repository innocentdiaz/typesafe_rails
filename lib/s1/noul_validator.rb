# frozen_string_literal: true

require "active_model"

# A validation that is a question. The record's default s1_state is the state
# when it has one, otherwise just the attribute; questions may point at fields
# with backticks either way.
#
#   validates :body, noul: "Is `body` a coherent support request?"
#   validates :note, noul: { with: "Does `note` ask us to write to a different address?", expect: false },
#                    if: :will_save_change_to_note?
#
# Options: with (the question), expect (default true), threshold, message.
class NoulValidator < ActiveModel::EachValidator
  def check_validity!
    raise ArgumentError, "noul: needs a question (`noul: \"...\"` or `noul: { with: \"...\" }`)" if options[:with].to_s.strip.empty?
  end

  # A Measurable record is judged as itself — its default form, under its declared
  # lens; anything else, as the attribute alone.
  def validate_each(record, attribute, value)
    subject = if record.respond_to?(:as_measurable)
                record.as_measurable(threshold: options[:threshold])
              else
                S1::Subject.new({ attribute => value }, owner: record, threshold: options[:threshold])
              end
    answer = subject.noul?(options[:with])
    record.errors.add(attribute, options[:message] || :invalid) unless answer == options.fetch(:expect, true)
  end
end
