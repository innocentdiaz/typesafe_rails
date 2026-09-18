# frozen_string_literal: true

module S1
  module Measurable
    # A record viewed through one of its forms: an S1::Subject that also
    # knows the record, so answers can be written back. Nested Measurable records
    # in the state serialize through their own default form.
    class Subject < S1::Subject
      attr_reader :record, :form, :args, :context

      # The lens is the model's declared one (measured_against), with per-call
      # context merged over it. With any lens the state is { this: facts, **lens };
      # with none, the facts alone.
      def initialize(record, form = :default, context: nil, threshold: nil, **args)
        @record = record
        @form = form
        @args = args
        @context = context
        rendered = Measurable::Subject.render(record.s1_state(form, **args), [record])
        lens = record.s1_lens.merge(context || {})
        super(lens.empty? ? rendered : { this: rendered, **Measurable::Subject.render(lens, [record]) },
              owner: record, form: form, threshold: threshold)
      end

      # Judged against context, still bound to the record: the form under `this`,
      # the context beside it, and the writes below still work.
      def given(**context) = Measurable::Subject.new(record, form, context: (self.context || {}).merge(context), threshold: @threshold, **args)
      alias against given

      # With S1.config.cache set, answers are keyed by the record's version, so
      # an unchanged record never asks twice; a write through update_ask bumps it.
      # ponytail: nested records don't bump the key — `touch: true` the association.
      # `questions` may also be an s1_enum name or a list of them.
      def ask(questions = nil, &)
        if questions.is_a?(Symbol) || questions.is_a?(Array)
          questions = Measurable::Questions.new(record).tap { |q| Array(questions).each { |id| q.field_question(id) } }
        end
        built = S1::Questions.coerce(questions, Measurable::Questions.new(record), &)
        cache = S1.config.cache
        return super(built, &nil) unless cache && record.respond_to?(:cache_key_with_version) && record.persisted? && !record.changed?

        cache.fetch(["s1", record.cache_key_with_version, form, args, context, built.transform_values(&:to_h)]) { super(built, &nil) }
      end

      def update_ask(questions = nil, &) = apply(ask(questions, &))
      def assign_ask(questions = nil, &) = assign(ask(questions, &))

      # Answers whose id is a column are assigned, coerced by column type; the rest
      # are returned untouched (ask speculatively, gate in code). A jsonb/json
      # `s1_answers` column, if present, keeps the raw answers per id.
      def assign(result)
        attributes = result.answers.select { |id, _| record.has_attribute?(id) }.to_h { |id, a| [id, coerce(id, a)] }
        attributes[:s1_answers] = record.s1_answers.to_h.merge(audit(result)) if record.has_attribute?(:s1_answers)
        record.assign_attributes(attributes)
        result
      end

      def apply(result)
        assign(result)
        record.save!
        result
      end

      # Nested measurables render through their own default form; a record met
      # again on the way down (`item: self` in its own form) renders as its
      # attributes instead of recursing.
      def self.render(value, seen = [])
        case value
        when Measurable then seen.include?(value) ? value.attributes : render(value.s1_state, seen + [value])
        when Hash      then value.to_h { |k, v| [k, render(v, seen)] }
        when Array     then value.map { |v| render(v, seen) }
        else value.respond_to?(:attributes) ? value.attributes : value
        end
      end

      private

      def coerce(id, answer)
        type = record.class.type_for_attribute(id.to_s).type
        case answer
        when S1::Answer::Noul   then type == :boolean ? answer.true?(threshold) : answer.to_f
        when S1::Answer::Choice then answer.to_s
        when S1::Answer::Score  then score_value(id, answer, type)
        end
      end

      # integer: the declared index for the level (or its position), numeric: the weighted position, else the label.
      def score_value(id, answer, type)
        case type
        when :integer then record.class.s1_fields.dig(id.to_sym, :indexes)&.fetch(answer.index) || answer.index
        when :float, :decimal then answer.to_f
        else answer.level
        end
      end

      def audit(result)
        result.answers.to_h do |id, a|
          [id.to_s, { "type" => a.type, "value" => a.to_s, "probabilities" => a.probabilities, "confidence" => a.confidence,
                      "form" => form.to_s, "model" => result.model, "at" => Time.now.utc.iso8601 }]
        end
      end
    end
  end
end
