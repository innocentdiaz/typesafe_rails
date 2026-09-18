# frozen_string_literal: true

require "active_support/concern"
require_relative "measurable/questions"
require_relative "measurable/subject"

module S1
  # A record that is measurable: it answers S1 questions about itself, and its
  # columns are where the measurements collapse.
  #
  #   class PhoneCall < ApplicationRecord
  #     include S1::Measurable
  #     s1_state                  { { transcript: live_transcript } }
  #     s1_state :quality_review  { { transcript: live_transcript, preferences: law_firm.preferences } }
  #   end
  #
  #   phone_call.noul?("Is the caller asking for a human?")            # default form
  #   phone_call.as(:quality_review).ask { |q| ... }                     # named form
  #   phone_call.update_ask { |q| q.noul :is_lead, "..." }               # answers -> columns
  #   PhoneCall.where(scored: false).update_ask_all(concurrency: 5) { |q, call| ... }
  #   PhoneCall.today.where_judged("Does the caller mention a competitor?", concurrency: 8)
  #
  # A form is a plain method (s1_state_<name>), so subclasses can override it and
  # forms can call each other. With no form declared, the state is #attributes.
  module Measurable
    extend ActiveSupport::Concern

    # A relation carrying `given(...)` context for the judgements down the chain.
    module Given
      attr_accessor :s1_context
    end

    # measure_on: → the Rails hook. before_validation measures synchronously; the rest enqueue.
    MEASURE_ON = { validation: :before_validation, create: :after_create_commit, save: :after_save_commit, update: :after_update_commit }.freeze

    class << self
      def models = (@models ||= [])

      # Every Measurable model's declarations against its schema. The Railtie runs
      # it after initialize when the app eager-loads; a spec can call it directly.
      def verify! = models.uniq.reject { |m| m.abstract_class? || !m.table_exists? }.each(&:s1_verify_fields!)
    end

    included { Measurable.models << self }

    class_methods do
      # How the record is measurable, under a name: the form.
      #   measurable_as(:review) { { transcript: transcript, preferences: firm.preferences } }
      def s1_state(name = :default, &block)
        s1_states << name unless s1_states.include?(name)
        define_method(:"s1_state_#{name}", &block)
      end
      alias_method :measurable_as, :s1_state

      # The model's default lens: what every measurement is judged against, unless
      # a call says otherwise. Evaluated per record, like a form. Alias measured_given.
      #   measured_against { { policy: store.refund_policy } }
      def measured_against(&block)
        define_method(:s1_lens) { instance_exec(&block).to_h }
      end
      alias_method :measured_given, :measured_against

      def s1_states = @s1_states ||= (superclass.respond_to?(:s1_states) ? superclass.s1_states.dup : [])

      # An enum that is also a choice question: the question, and a description
      # per value.
      #   measured_enum :status, "What is the sender reporting?", delivered: "Handed over", attempted: "Tried, no one there"
      # Declares `enum :status` (string-backed unless `values:` is given; other
      # keywords go to `enum`). Then `q.choice :status` needs nothing else, and
      # `update_ask(:status)` asks it. With just a name, returns the descriptions.
      def s1_enum(name, question = nil, **descriptions)
        return s1_enums.fetch(name.to_sym) { raise ArgumentError, "#{self} has no s1_enum #{name.inspect}" } if descriptions.empty?

        s1_measure_on(name, **descriptions.extract!(:measure_on, :if, :unless, :on))
        options = descriptions.extract!(:values, :prefix, :suffix, :scopes, :default, :validate, :instance_methods)
        values = s1_enum_values(name, options.delete(:values), descriptions.keys)
        enum(name, values, **options)
        s1_questions[name.to_sym] = question if question
        s1_enums[name.to_sym] = descriptions.transform_keys(&:to_sym).freeze
      end
      alias_method :measured_enum, :s1_enum
      alias_method :choice_enum, :s1_enum

      # How a column is measured, declared once; then `update_measure(:is_lead)`.
      # The kind follows the column: boolean or float → judge (a float keeps the
      # probability), integer → score (give the levels; a float with levels is a
      # score too), string or enum → choose (give the options, or s1_enum).
      #   measured_field :is_lead,  "Is this a potential new client?"
      #   measured_field :severity, "How severe?", { "none" => 0, "minor" => 1, "serious" => 2 }   # integer column: explicit indexes
      #   measured_field :team,     "Which team?", returns: "Refunds", billing: "Charges"
      #
      # A score stored as an integer is stored by index. Positional levels
      # (`"none", "minor", "serious"`) shift every stored value the day a level
      # is inserted — the same foot-gun as an array-backed Rails enum. Give the
      # indexes explicitly, { level => integer }; a bare list on an integer
      # column is accepted but warns loudly.
      def s1_field(name, question, *levels, **options)
        s1_measure_on(name, **options.extract!(:measure_on, :if, :unless, :on))
        levels, indexes = s1_levels(name, levels)
        s1_questions[name.to_sym] = question
        s1_fields[name.to_sym] = { levels: levels, indexes: indexes, options: options }.compact_blank.freeze
      end
      alias_method :measured_field, :s1_field
      alias_method :measured_attribute, :s1_field
      alias_method :measurable_field, :s1_field

      # When a measured field is measured, on the Rails lifecycle. before_validation
      # is synchronous (assign_measure: the column exists at insert, validations see
      # it); the after-commit hooks enqueue (update_measure_later). Fields on the
      # same trigger are measured together — one call. if: / unless: / on: pass
      # through to the callback.
      #   measured_field :match, "…", measure_on: :validation, if: :will_save_change_to_story?
      #   measured_enum  :category, "…", a: "…", b: "…", measure_on: :create
      def s1_measure_on(name, measure_on: nil, **conditions)
        return unless measure_on

        hook = MEASURE_ON.fetch(measure_on.to_sym) { raise ArgumentError, "measure_on: must be one of #{MEASURE_ON.keys.inspect} (got #{measure_on.inspect})" }
        key = [hook, conditions]
        (s1_triggers[key] ||= []) << name.to_sym
        return if s1_triggers[key].size > 1 # the callback is registered once per trigger; it reads the list at run time

        fields = s1_triggers[key]
        if hook == :before_validation
          before_validation(**conditions) { assign_measure(*fields) }
        else
          public_send(hook, **conditions) { update_measure_later(*fields) }
        end
      end

      def s1_triggers = @s1_triggers ||= (superclass.respond_to?(:s1_triggers) ? superclass.s1_triggers.dup : {})

      def s1_enums = @s1_enums ||= (superclass.respond_to?(:s1_enums) ? superclass.s1_enums.dup : {})
      def s1_questions = @s1_questions ||= (superclass.respond_to?(:s1_questions) ? superclass.s1_questions.dup : {})
      def s1_fields = @s1_fields ||= (superclass.respond_to?(:s1_fields) ? superclass.s1_fields.dup : {})

      # Which measurement a column takes: from s1_enum / s1_field / enum, else the column type.
      def s1_kind(name)
        return :choice if s1_enums.key?(name.to_sym) || defined_enums.key?(name.to_s) || s1_fields.dig(name.to_sym, :options)
        return :score  if s1_fields.dig(name.to_sym, :levels)

        case type_for_attribute(name.to_s).type
        when :boolean, :float, :decimal then :noul # a float keeps a judge's probability; with levels (above) it is a score
        when :integer then :score
        when :string, :text then :choice
        else raise ArgumentError, "#{self} cannot tell how to measure #{name.inspect}: declare it with s1_field or s1_enum"
        end
      end

      # Checks this model's declarations against its schema. Raised by S1::Measurable.verify!
      # at boot; call it in a spec to keep it green.
      #   - every measured_field / s1_enum names a real column
      #   - a score field sits on a numeric or string column, a judge on a boolean, a choose on a string / enum
      #   - a score on an integer column has explicit indexes (else it warns)
      def s1_verify_fields!
        (s1_fields.keys + s1_enums.keys).each do |name|
          raise ArgumentError, "#{self}: measured field #{name.inspect} is not a column" unless column_names.include?(name.to_s)
        end
        s1_fields.each do |name, field|
          type = type_for_attribute(name.to_s).type
          kind = s1_kind(name)
          ok = { noul: %i[boolean float decimal], score: %i[integer float decimal string text], choice: %i[string text] }.fetch(kind)
          raise ArgumentError, "#{self}: #{name.inspect} is measured as #{kind} but its column is #{type}" unless ok.include?(type)

          next unless kind == :score && type == :integer && !field[:indexes]

          s1_warn("#{self}: #{name.inspect} is a score on an integer column with positional levels — " \
                  "give explicit indexes { level => integer }; a level inserted later shifts every stored value")
        end
        self
      end

      # Options for a choice named after an enum: s1_enum descriptions, else the
      # plain enum's keys. Nil when there is no such enum, unless required.
      def s1_choices(name, required: false)
        s1_enums[name.to_sym] || defined_enums[name.to_s]&.keys&.to_h { |k| [k.to_sym, nil] } ||
          (raise ArgumentError, "#{self} has no s1_enum or enum #{name.inspect}" if required)
      end

      # On a relation, three things: measure_all keeps the distributions and
      # writes nothing; update_measure_all collapses into the columns; where_judged
      # / where_same_as filter. `concurrency` asks run at a time; writes stay on
      # the calling thread. The block also receives the record.
      def measure_all(*questions, as: :default, concurrency: 1, given: nil, &block)
        s1_map(as: as, concurrency: concurrency, given: given) { |s| s.ask(one_or_many(questions)) { |q| block&.call(q, s.record) } }
          .to_h { |s, result| [s.record, result] }
      end
      alias_method :ask_all, :measure_all

      # measure_all, then collapse each Result into its record's columns. Returns { record => Result }.
      def update_ask_all(*questions, as: :default, concurrency: 1, given: nil, &block)
        s1_map(as: as, concurrency: concurrency, given: given) { |s| s.ask(one_or_many(questions)) { |q| block&.call(q, s.record) } }
          .to_h { |s, result| [s.record, s.apply(result)] }
      end
      alias_method :update_measure_all, :update_ask_all

      # The records for which the question is judged true / false. One call per
      # record, `concurrency` at a time; returns a relation (`where(id: ...)`), so
      # ActiveRecord continues after it. `where_judged` is the relation's `judge?`;
      # `measure_select` / `measure_reject` are the same, named as Enumerable would.
      #   Item.unclaimed.where_judged("Is this worth keeping?", concurrency: 8)
      # Context for every judgement down the chain, as a scope:
      #   Item.unclaimed.given(note: policy).where_judged_not("Is `this` worth keeping, per `note`?")
      # (or per call: where_judged("…", given: { note: policy })). Alias `against`.
      def given(**context) = all.extending(Measurable::Given).tap { |r| r.s1_context = context }
      alias_method :against, :given

      # The filters return a relation, so ActiveRecord continues after them:
      #   Item.unclaimed.where_judged_not("…").destroy_all
      def where_judged(question, as: :default, concurrency: 1, given: nil, **)
        yes = s1_map(as: as, concurrency: concurrency, given: given) { |s| s.noul?(question, **) }
        where(id: yes.filter_map { |s, judged| s.record.id if judged })
      end
      alias_method :measure_select, :where_judged
      alias_method :s1_select, :where_judged

      def where_judged_not(question, as: :default, concurrency: 1, given: nil, **)
        yes = s1_map(as: as, concurrency: concurrency, given: given) { |s| s.noul?(question, **) }
        where(id: yes.filter_map { |s, judged| s.record.id unless judged })
      end
      alias_method :measure_reject, :where_judged_not
      alias_method :s1_reject, :where_judged_not

      # The relation's is? / is-not: the predicate completes "Is this …?".
      #   Item.unclaimed.given(note: policy).where_is_not("worth keeping")
      def where_is(predicate, **) = where_judged("Is this #{predicate}?", **)
      def where_is_not(predicate, **) = where_judged_not("Is this #{predicate}?", **)

      # The records that describe the same thing as `other` — the relation's
      # same_as? / ===, with concurrency. `grep(ψ other)` is the sequential spelling.
      #   Item.unclaimed.where_same_as(params[:Body], concurrency: 8)
      def where_same_as(other, as: :default, concurrency: 1, **)
        same = s1_map(as: as, concurrency: concurrency) { |s| s.same_as?(other, **) }
        where(id: same.filter_map { |s, judged| s.record.id if judged })
      end
      alias_method :measure_grep, :where_same_as

      private

      # Levels as the ordered texts the model sees, and (from a { text => integer }
      # hash) the integer each stores as.
      def s1_levels(name, levels)
        return [levels, nil] unless levels.one? && levels.first.is_a?(Hash)

        mapping = levels.first
        ordered = mapping.sort_by { |_, i| i }
        unless ordered.map(&:last).uniq.size == ordered.size && ordered.all? do |_, i|
          i.is_a?(Integer)
        end
          raise ArgumentError,
                "#{self}: #{name.inspect} indexes must be distinct integers"
        end

        [ordered.map { |text, _| text.to_s }, ordered.map(&:last)]
      end

      # String-backed by default (stored by name: safe to reorder). A positional
      # Array is Rails' array-enum foot-gun, opted into — it warns.
      def s1_enum_values(name, values, keys)
        return keys.to_h { |k| [k, k.to_s] } unless values
        return values unless values.is_a?(Array)

        s1_warn("#{self}: #{name.inspect} is an enum with positional values #{values.inspect} — an option inserted later shifts every stored value; " \
                "prefer the string-backed default or an explicit { option => integer }")
        keys.zip(values).to_h
      end

      def s1_warn(message)
        (S1.config.logger || Kernel).warn("[s1] #{message}")
      end

      def one_or_many(questions) = questions.size <= 1 ? questions.first : questions

      # [subject, value] per record; the block runs in a thread and must not touch the database.
      # Context comes from `given:` or from a `given(...)` scope up the chain.
      def s1_map(as:, concurrency:, given: nil)
        context = given || (all.respond_to?(:s1_context) ? all.s1_context : nil)
        all.find_each.each_slice([concurrency, 1].max).flat_map do |slice|
          subjects = slice.map { |record| record.as(as, given: context) }
          subjects.zip(subjects.map { |s| Thread.new { yield s } }.map(&:value))
        end
      end
    end

    def s1_state(name = :default, **args)
      form = :"s1_state_#{name}"
      return public_send(form, **args) if respond_to?(form)
      raise ArgumentError, "#{self.class} has no s1_state #{name.inspect}" unless name == :default

      respond_to?(:attributes) ? attributes : to_h
    end

    def as(name = :default, given: nil, threshold: nil, **args) = Measurable::Subject.new(self, name, context: given, threshold: threshold, **args)

    # No measured_against declared: no lens.
    def s1_lens = {}
    alias as_measurable as

    # Judged against context — the direct spelling of what a form does persistently.
    def given(**) = as.given(**)
    alias against given
    # S1.to_state(record) / ψ(record); ψ(record, as: :thread, last: 10)
    def to_s1(as: :default, given: nil, **args) = self.as(as, given: given, **args)

    # The verbs, on the record's default form — the verb measures, the noun (or `?`)
    # collapses, as on a Subject: x.noun(args) == x.verb(args).collapse. A declared
    # column name stands for its question everywhere: `item.choose(:category)`,
    # `item.judge?(:plausible)`, `item.measure(:plausible, :match)` — measured, nothing written.
    def judge(question, **) = question.is_a?(Symbol) ? measured(question) : as.judge(question, **)
    alias noul judge
    def judge?(question, threshold: nil, **) = judge(question, **).collapse(threshold || as.threshold)
    alias noul? judge?
    alias ask? judge?
    def is(...) = as.is(...)
    def is?(...) = as.is?(...)
    def choose(question, **) = question.is_a?(Symbol) ? measured(question) : as.choose(question, **)
    def choice(...) = choose(...).collapse
    def score(question, *levels, **) = question.is_a?(Symbol) ? measured(question) : as.score(question, *levels, **)
    def level(...) = score(...).collapse
    def ask(*questions, &) = as.ask(one_or_many(questions), &)
    alias measure ask
    alias batch ask
    alias ask_about ask

    def measured(column) = as.ask(column)[column]
    private :measured

    # `questions`: a block, a Questions, a Hash, or column names (`update_measure(:is_lead, :severity)`).
    def update_ask(*questions, as: :default, given: nil, **args, &block)
      self.as(as, given: given, **args).update_ask(one_or_many(questions)) { |q| block&.call(q, self) }
    end
    alias update_measure update_ask

    # Same, without saving — for enrichment inside a save:
    #   before_save -> { assign_ask { |q| q.choice :department, "Which team?", **DEPARTMENTS } },
    #               if: :will_save_change_to_body?
    def assign_ask(*questions, as: :default, given: nil, **args, &block)
      self.as(as, given: given, **args).assign_ask(one_or_many(questions)) { |q| block&.call(q, self) }
    end
    alias assign_measure assign_ask

    # Same, enqueued. The block runs now (so it can read the record); the ask runs
    # in S1::AskJob. Extra keywords are the form's arguments.
    def update_ask_later(*questions, as: :default, given: nil, **args, &block)
      questions = one_or_many(questions)
      if questions.is_a?(Symbol) || questions.is_a?(Array) # column names: each column's own question
        questions = Measurable::Questions.new(self).tap { |q| Array(questions).each { |id| q.field_question(id) } }
      end
      built = S1::Questions.coerce(questions, Measurable::Questions.new(self)) { |q| block&.call(q, self) }
      S1::AskJob.perform_later(self, as.to_s, built.transform_keys(&:to_s).transform_values(&:to_h),
                               args.transform_keys(&:to_s), given&.transform_keys(&:to_s))
    end
    alias update_measure_later update_ask_later

    def one_or_many(questions) = questions.size <= 1 ? questions.first : questions
    private :one_or_many
  end
end
