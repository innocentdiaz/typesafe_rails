# frozen_string_literal: true

module S1
  module Measurable
    # The batch builder a record's questions are built with. Adds one thing to
    # S1::Questions: a choice can take its options from the model.
    #
    #   q.choice :status                                                  # question + options from s1_enum :status
    #   q.choice :status, "What is the sender reporting?"                 # options from s1_enum :status (or enum :status)
    #   q.choice :outcome, "What is the sender reporting?", enum: :status
    class Questions < S1::Questions
      def initialize(record)
        super()
        @record = record
      end

      def choice(id, instructions = nil, criteria: nil, choices: nil, enum: nil, **options)
        criteria ||= choices
        from_model = enum || (options.empty? && criteria.nil?)
        options = @record.class.s1_choices(enum || id, required: !enum.nil?) || field(id)[:options] || options if from_model
        super(id, instructions || question_for(enum || id), criteria: criteria, **options)
      end
      alias choose choice

      def noul(id, instructions = nil, **)
        super(id, instructions || question_for(id), **)
      end
      alias judge noul

      def score(id, instructions = nil, *levels, **)
        levels = field(id)[:levels] || [] if levels.empty?
        super(id, instructions || question_for(id), *levels, **)
      end

      # The column's own kind of measurement (s1_kind), with its declared question.
      def field_question(id) = public_send(@record.class.s1_kind(id), id)

      private

      def field(id) = @record.class.s1_fields.fetch(id.to_sym, {})

      def question_for(id)
        @record.class.s1_questions.fetch(id.to_sym) do
          raise ArgumentError, "#{@record.class} has no declared question for #{id.inspect} (s1_field / s1_enum)"
        end
      end
    end
  end
end
