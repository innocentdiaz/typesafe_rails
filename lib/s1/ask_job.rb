# frozen_string_literal: true

require "active_job"

module S1
  # update_ask off the request thread. Questions travel as their #to_h; transient
  # provider failures retry with ActiveJob's backoff.
  #
  #   ticket.update_ask_later(as: :with_plan) { |q| q.choice :department, "Which team?", **departments }
  class AskJob < ActiveJob::Base
    retry_on TransientError, wait: :polynomially_longer, attempts: 5

    def perform(record, form, questions, args = {}, given = nil)
      record.as(form.to_sym, given: given&.symbolize_keys, **args.symbolize_keys)
            .update_ask(questions.transform_values { |h| S1::Question.from_h(h) })
    end
  end
end
