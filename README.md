# s1-rails

![preview](https://github.com/innocentdiaz/s1_rails/blob/master/preview.png?raw=true)

s1-rails applies [s1-ruby](https://github.com/innocentdiaz/s1_ruby) (s1-model choices/judgements as Ruby primitives).

s1-rails applies [s1-ruby](https://github.com/innocentdiaz/s1_ruby) (s1-model choices/judgements as Ruby primitives) where Rails keeps its data. An ActiveRecord **record** is measurable, a **column** is where a measurement collapses, a **relation** is a stream. Validations, callbacks, ActiveJob and notifications are where the verbs plug in.

**TABLE of CONTENTS**

- [TL;DR](#tldr)
- [The idea, applied to Rails](#the-idea-applied-to-rails) — measurable · lens · measure · collapse · stream · where the verbs plug in
- [Install](#install)
- [Declaring](#declaring) — [forms](#forms-how-a-record-is-measurable) · [the lens](#the-lens-what-a-record-is-judged-against) · [`measured_field`](#measured_field-how-a-column-is-measured) · [`measured_enum`](#measured_enum-an-enum-that-is-a-choice)
- [Measuring](#measuring) — the verbs on a record · `given` per call
- [Collapsing](#collapsing) — [`update_measure`](#update_measure-measure-collapse-save) · [`assign_measure`](#assign_measure-collapse-without-saving) · [`update_measure_later`](#update_measure_later-off-the-request-thread) · [callbacks and validations](#callbacks-and-validations)
- [Streams](#streams) — [a relation: measure, collapse, or filter](#a-relation-measure-collapse-or-filter) · [`measure_all`](#measure_all-a-relation-measured) · [`update_measure_all`](#update_measure_all-a-relation-collapsed) · [`where_judged`](#where_judged--where_is--where_same_as-a-relation-filtered) · [predicates](#predicates-over-relations)
- [Plumbing](#plumbing) — [caching](#caching) · [cost and telemetry](#cost-and-telemetry) · [testing](#testing) · [the boot check](#the-boot-check)
- [Explicit vs Rails primitive](#explicit-vs-rails-primitive)
- [Dictionary and aliases](#dictionary-and-aliases)
- [Usage scenarios](#usage-scenarios) — models · callbacks · controllers and webhooks · mail · batch and console

## TL;DR

A lost-and-found office. Things get found on trains; people text to say something is theirs.
Two models, one judgement between them, and every Rails seam the verbs plug into.

```ruby
class Item < ApplicationRecord                       # something found on a train
  has_many :claims

  include S1::Measurable
  measurable_as { { found: description, where: line, since: created_at&.strftime("%Y-%m-%d") } }   # created_at is nil before the first save

  measured_enum :category, "What is it?",
    umbrella: "an umbrella",
    phone: "a phone",
    bag: "a bag or case",
    other: "anything else",
    measure_on: :create                            # collapse into the column, off the request thread (a job)

  scope :unclaimed, -> { where(claimed: false) }
end

class Claim < ApplicationRecord                      # someone says it's theirs
  belongs_to :item

  include S1::Measurable
  measurable_as { { story: story, item: item } }     # the item renders through its own form — an association is a nested measurable

  measured_field :plausible, "Is `story` a plausible account of losing the `item`?",   # float columns: the probabilities, kept
                 measure_on: :validation, if: :will_save_change_to_story?             # measured inside the save, before validations —
  measured_field :match,     "Is `story` describing the same object as `item`?",      # both fields, one call
                 measure_on: :validation, if: :will_save_change_to_story?
  validates :plausible, numericality: { greater_than: 0.5, message: "doesn't sound like this item" }   # the gate, in Rails' own words
  scope :likely, -> { where(match: 0.8..) }          # the collapse happens in SQL, later, at whatever threshold the query wants
end

# app/controllers/claims_controller.rb — an inbound SMS: "left my black umbrella on the 8:15 this morning, wooden handle"
def create
  item = Item.unclaimed.where(created_at: 1.week.ago..).where_same_as(params[:body], concurrency: 8).first   # which item is this text about?
  return redirect_to root_path, notice: "Nothing like that has been handed in yet." unless item

  claim = Claim.new(item: item, story: params[:body])          # measures plausibility and match, validates, saves
  claim.save ? redirect_to(claim) : redirect_to(root_path, alert: claim.errors.full_messages.to_sentence)
end

# a nightly cleanup: a relation is a stream, and the where_ verbs return relations
Item.unclaimed
    .where(created_at: ..30.days.ago)
    .given(note: "we keep anything with an owner's name or over £20")        # context for every judgement down the chain
    .where_is_not("worth keeping", concurrency: 8)                          # the relation's is?: "Is this worth keeping?"
    .destroy_all
Claim.likely.count                                   # how many claims are probably right — no threshold was ever hard-coded
```

Read down the right-hand side: `measured_enum … measure_on: :create` (a job), `measured_field …
measure_on: :validation` (a callback) feeding a plain `validates :plausible, numericality:` (a
validation on the measured column), `where_same_as(text)` (a cross-record judgement over the
relation), `where_is_not` (a stream), `where(match: 0.8..)` (the collapse, deferred to the query).
[This example runs](spec/s1/lost_and_found_spec.rb) against the Stub provider.

## The idea, applied to Rails

s1's foundation is three steps — **ψ makes measurable**, **the verbs measure**, **`?` decides
(collapse)** — with plain Ruby between; its README owns the theory. Rails already has a place for
each step.

```
Record  +  Form (given)  ──measurable_as──▶  measurable  ──judge / choose / score──▶  probabilities  ──column type──▶  the row
                                                                                            │
Relation (a stream)  ──where_judged · update_measure_all · &ψ.is──▶  one call per record       float keeps it · boolean / integer / string collapse it
```

**Measurable is a form.** `measurable_as { { subject: subject, body: body } }` says what the
record looks like to the model: the state, the facts. `(ψ record)` is `record.as_measurable` —
a record defines `to_s1`, so the symbol, `S1.to_state` and every predicate convert it through its
default form.

**The lens is what it is judged against.** A plan, a policy, a firm's criteria: `measured_against`
declares it once, `given` supplies it per call, and the state becomes `{ this: facts, **lens }`.
Forms and the lens are the persistent spelling of s1's `given`: what the record is judged
against travels with the record instead of being passed at every call.

**Measure is a verb on the record.** `judge`, `choose`, `score`, `measure` (several at once)
live on the record and delegate to its default form. The verb measures, the noun collapses —
`ticket.judge "…"` is a probability, `ticket.judge? "…"` a boolean; `choose` an
`Answer::Choice`, `choice` the option; `score` an `Answer::Score`, `level` the level (an
`S1::Level`) — exactly as on a Subject, and by the same identity: the noun is
`verb(...).collapse`, so `ticket.level(…) == ticket.score(…).collapse`.

**Collapse is a write.** `update_measure` / `assign_measure` measure and put the answers into
columns, and **the column type is the collapse policy**: a boolean column collapses a judge at
the threshold, a float column keeps its probability, an integer column keeps a score's index,
a string column the level or the option. Schema says how much of the distribution survives; a
json `s1_answers` column keeps the whole measurement beside its collapse.

**A relation is a stream.** `where_judged` / `where_is` / `where_same_as` filter it,
`update_measure_all` collapses every row, `measure_all` measures without writing, and s1's
predicates (`&ψ.is`, `&ψ.choose`, `&ψ.score`, `&ψ.judge`) work on records directly, so
`select`, `group_by`, `sort_by` and `sum` over a relation are semantic.

**The questions are declared on the schema.** `measured_field` and `measured_enum` put each
column's question, levels and option descriptions next to the column, so
`update_measure(:column)` needs nothing else and the preference is written once.

**Facts, lens, questions.** Every measurement has three axes, declared once or chosen per call,
and every verb takes all three the same way:

| axis | what it answers | declared | per call |
|---|---|---|---|
| **facts** | what is measured | `measurable_as` (forms) | `as: :thread` |
| **lens** | what it is judged against | `measured_against` | `given: { … }` / `.given(…)` |
| **questions** | which measurements | `measured_field` / `measured_enum` | the block, or column names |

**Where the verbs plug in.** Validations: `validates :body, noul: "…"` — a judgement that
gates a save. Callbacks: `measure_on: :validation`, or `assign_measure` in `before_validation`,
the collapse landing inside the same save. Jobs: `update_measure_later` runs the ask in
`S1::AskJob`. Notifications: every call emits `ask.s1`, the ledger's hook.

## Install

```ruby
gem "s1-rails"
```

```ruby
# config/initializers/s1.rb — only what differs from the defaults
S1.configure do |c|
  c.typesafe.api_key = Rails.application.credentials.typesafe_api_key
  c.cache            = Rails.cache
  c.symbol           = true         # defines ψ; every ψ in this README assumes it
end
```

The Railtie sets `logger` to `Rails.logger` and makes the ambient subject (`S1.about`)
fiber-safe. Ruby ≥ 3.2, Rails ≥ 7.1. s1's own settings (`provider`, `threshold`, `primitives`)
are documented in its README.

# Declaring

## Forms: how a record is measurable

`measurable_as` (alias `s1_state`) declares the state once: the facts. Declare several, named,
when different questions need different views of the same record; pick one with
`as_measurable` (alias `as`). A form is the persistent spelling of `given`: what the record is
judged against travels with it.

```ruby
class SupportTicket < ApplicationRecord
  include S1::Measurable

  measurable_as           { { subject: subject, body: body } }                                 # :default — what the ticket is
  measurable_as(:thread)  { |last: 5| { subject: subject, messages: messages.last(last).map(&:body) } }   # another view of the facts
end

ticket.as_measurable(:thread, last: 10).judge?("...")
ticket.update_measure(as: :thread) { |q| ... }
(ψ ticket)                                                              # the default form, as a Subject
(ψ ticket, as: :thread, last: 10)                                       # a named one, with arguments
```

Each form is an instance method (`s1_state_thread`), so subclasses override it and forms
can call each other. A nested record that is itself `Measurable` is rendered through its own
default form; any other record contributes its `attributes`; a record met inside its own form
(`item: self`) is its `attributes` rather than a recursion. A model with no form at all is its
`attributes`. `as_measurable` returns an `S1::Subject` that also knows its record — the
same verbs, plus the writes under [Collapsing](#collapsing) — tagged `owner: record, form: name`
for the ledger.

A named form earns its place when the *facts* differ (`:thread` is a different view); "with
the policy attached" is not a different record, it is a different lens.

## The lens: what a record is judged against

A form holds facts — what a measurement is *of*. The lens — a plan, a policy, a firm's criteria —
is what it is judged *against*; it goes beside the facts, never among them. `measured_against`
(alias `measured_given`) declares the model's default lens, evaluated per record like a form;
`given:` on any verb, or the fluent `.given(…)` (alias `against`, "judged against"), merges
per-call context over it.

```ruby
class SupportTicket < ApplicationRecord
  include S1::Measurable
  measurable_as    { { subject: subject, body: body } }         # the facts
  measured_against { { policy: store.refund_policy } }          # the lens, by default — evaluated per record, like a form
  measured_field :within_policy, "Is `this` within `policy`?", measure_on: :validation   # a declared trigger can use it
end

ticket.is? "within policy"                                     # state sent: { this: { subject:, body: }, policy: … }
ticket.update_measure(:within_policy, given: { policy: strict })   # per-call given: merges over the declared lens
ticket.given(plan: customer.plan).is? "covered by `plan`"          # fluent, same merge
SupportTicket.open.given(policy: p).where_is("within policy")      # a stream, same axes
ticket.update_measure_later(:within_policy, given: { policy: p })  # the job carries it
```

With any lens the state is `{ this: facts, **lens }`; with none, the facts alone — so a model
without `measured_against` behaves exactly as before. `given` on a record puts the default form
under `this` and the context beside it, for one call; `measured_against` does the same job for
every call.

## measured_field: how a column is measured

Declare a column's question once; the kind follows the column — boolean or float → judge (a
float keeps the probability), integer → score (give the levels; a float with levels is a score
too), string or enum → choose (give the options, or a `measured_enum`). Then `update_measure(:column, …)` needs nothing else. Aliases
`measured_attribute`, `s1_field`, `measurable_field`.

```ruby
measured_field :is_lead,  "Is this a potential new client?"
measured_field :severity, "How severe is the issue?", { "Cosmetic" => 0, "Degraded" => 1, "Blocking" => 2 }
measured_field :team,     "Which team?", returns: "Refunds", billing: "Charges"
```

**A score on an integer column is stored by index — give the indexes.** Positional levels
(`"Cosmetic", "Degraded", "Blocking"`) mean `1` is "Degraded" until the day someone inserts
"Minor" in the middle and every stored `1` silently becomes "Minor" — the same foot-gun as an
array-backed Rails `enum`, and the same remedy: an explicit `{ level => integer }`, which makes
adding a level an append and changing one a migration. A bare list on an integer column is
accepted and **warns loudly** at declaration; a `string` column stores the level's text and has
no such problem.

**When.** A declaration says how a column is measured, not when; nothing measures until a verb
runs. `measure_on:` puts the verb on the Rails lifecycle, and the lifecycle already decides sync
vs async: a `before_*` hook must produce the value now, an `after_*_commit` hook can enqueue.

| `measure_on:` | hook | how |
|---|---|---|
| `:validation` | `before_validation` | sync — `assign_measure`; the column exists at insert, validations can read it, the save absorbs the call |
| `:create` | `after_create_commit` | async — `update_measure_later`; the request returns, the column fills in a moment |
| `:save` | `after_save_commit` | async, every create or update |
| `:update` | `after_update_commit` | async, updates only |
| omitted | — | on demand: `record.update_measure(:column)` |

`if:` / `unless:` / `on:` pass through to the callback. Fields on the same trigger are measured
together — one call, not one per field.

```ruby
measured_enum  :category, "What is it?", umbrella: "…", other: "…", measure_on: :create
measured_field :match,    "Is `story` describing the same object as `item`?", measure_on: :validation, if: :will_save_change_to_story?
```

**On demand.** Without `measure_on:` nothing runs by itself; a declared column name stands for
its question in every verb:

```ruby
item.update_measure(:category)               # measure, collapse into the column, save
item.assign_measure(:category)               # collapse into the attribute, no save
item.update_measure_later(:category)         # enqueue
Item.where(category: nil).update_measure_all(:category, concurrency: 5)
item.choose(:category)                       # the measurement alone — an Answer, nothing written
item.judge?(:plausible)                      # the decision alone
item.measure(:plausible, :match)             # several, one call, nothing written
```

`Model.s1_kind(:column)` is the resolution: a `measured_enum`, a plain `enum` or declared
options make it a choice; declared levels make it a score; otherwise the column type decides,
and a type it cannot read (a datetime) raises until the column is declared.

**Declarations are checked against the schema.** `S1::Measurable.verify!` walks every
`Measurable` model: a measured field that is not a column raises; a kind that does not fit its
column (`options` on a boolean, a judge on a string) raises; positional score levels on an
integer column warn. The Railtie runs it at boot (see [the boot check](#the-boot-check));
keep it green in a spec:

```ruby
it "measures what the schema has" do
  expect { S1::Measurable.verify! }.not_to raise_error
end
```

## measured_enum: an enum that is a choice

An enum that is also a choice question: the question, and a description per value — declared
once, asked anywhere. Aliases `s1_enum`, `choice_enum`.

A choice is stored **by name** — string-backed by default — so inserting an option later is safe;
the by-position foot-gun belongs to scores, whose integer *is* the order. Integer-backed enums are
fine when the integers are explicit; only positional ones are the problem — the same distinction
Rails draws between `enum status: { a: 0, b: 1 }` and `enum status: [:a, :b]`.

```ruby
measured_enum :category, "What is it?", personal: "…", other: "…"                                       # string-backed: stored as "personal"
measured_enum :category, "What is it?", values: { personal: 0, other: 1 }, personal: "…", other: "…"   # integer-backed, explicit: stable
measured_enum :category, "What is it?", values: [0, 1], personal: "…", other: "…"                       # positional: warns
```

`measured_field :category, "…", umbrella: "…", other: "…"` measures the same way and stores the
same option text; what `measured_enum` adds is Rails' `enum` — `item.umbrella?`, the
`Item.umbrella` scope, `Item.categories`, and a guard against values outside the set. Use
`measured_field` when the options are the model's business, `measured_enum` when they are the
app's. It is not folded into `measured_field` because an enum defines methods named after your
options, which a declaration called "field" should not do silently.

```ruby
class Delivery < ApplicationRecord
  include S1::Measurable
  measured_enum :status, "What is the sender reporting?",
          delivered: "Handed over or left somewhere", attempted: "Tried, no one there", undeliverable: "Bad address"
  measurable_as(:sms) { |body:| { message: body } }
end

Delivery.statuses            # => { "delivered" => "delivered", ... }   a normal enum (string-backed; `values:` for integers)
Delivery.s1_enum(:status)    # => { delivered: "Handed over or left somewhere", ... }

delivery.update_measure(:status, as: :sms, body: text)                        # ask the enum's question, write the column
delivery.update_measure(as: :sms, body: text) { |q| q.choose :status }        # same, inside a batch
delivery.choose("What happened?", enum: :status)                              # your question, its options
```

A `choose` with no options takes them from the `measured_enum` (or plain `enum`) of the same
name; with no question, the enum's. `update_measure` / `assign_measure` / `measure` accept an
enum name or a list of them in place of a block. Other keywords (`prefix:`, `suffix:`,
`default:`, `values:`, …) pass through to `enum`.

# Measuring

The verbs live on the record and measure through its default form (`as:` picks another).
Nothing is written; what comes back is a **collapsable** — the distribution, which can also just
collapse — exactly as on a Subject: an `Answer::Noul` / `Choice` / `Score` for one measurement,
a `Result` for `measure { … }`. No `?` keeps the probability; `?`, `collapse` and `!!` collapse
it; a `Result` collapses to a hash and pattern-matches.

```ruby
ticket.judge  "Is the customer asking for a human agent?"   # => #<S1::Answer::Noul 0.7>   the probability, kept
ticket.judge? "Is the customer asking for a human agent?"   # => true                       the decision
ticket.is  "angry"                                          # "Is this angry?" — the phrase completes the question
ticket.is? "angry"
ticket.choose "Which team should handle this?", returns: "Refunds", billing: "Charges"   # => #<S1::Answer::Choice>
ticket.choice "Which team should handle this?", returns: "Refunds", billing: "Charges"   # => :returns
ticket.score  "How severe is the issue?", "Cosmetic", "Degraded", "Blocking"             # => #<S1::Answer::Score>
ticket.level  "How severe is the issue?", "Cosmetic", "Degraded", "Blocking"             # => "Degraded"   an S1::Level
ticket.measure do |q|                                                                    # several, one call, independent
  q.judge  :escalate,   "Is the customer asking for a human agent?"
  q.choose :department, "Which team should handle this?", returns: "Refunds", billing: "Charges"
  q.score  :severity,   "How severe is the issue?", "Cosmetic", "Degraded", "Blocking"
end
```

The rule of thumb, for every verb and its stream twin: does the argument read as a question
("Is the customer angry?") → `judge?` / `where_judged`; as a phrase ("angry") → `is?` /
`where_is`. A declared column name stands for its question in every verb —
`item.choose(:category)`, `item.judge?(:plausible)`, `item.measure(:plausible, :match)` — see
[`measured_field`](#measured_field-how-a-column-is-measured).

`given` per call is the lens for one measurement: the default form becomes `this`, the context
sits beside it, merged over any declared `measured_against`.

```ruby
ticket.given(plan: customer.plan, policy: store.refund_policy).is? "within policy"
ticket.given(plan: customer.plan).judge? "Is `this` covered by `plan`?"
```

# Collapsing

## update_measure: measure, collapse, save

Measure, collapse into the columns, save. Question ids that name a column are written,
coerced by column type; every other answer is only returned — ask speculatively, gate in code.
Column names alone ask each column's declared question (`measured_field` / `measured_enum`):
`ticket.update_measure(:escalate, :department)`. Alias `update_ask`.

The column type is the collapse policy:

| answer | boolean | float / decimal | integer | string / enum |
|---|---|---|---|---|
| noul | `true?` at the threshold | probability | — | — |
| choice | — | — | — | the option |
| score | — | weighted position | level index | level text |

A "—" is a pairing that means nothing: nothing stops the write (a probability into an integer
column arrives as `0`), but `S1::Measurable.verify!` rejects it for any declared field, so
declare your columns and run the boot check.

`save!` runs, so validations and callbacks apply. Add a json/jsonb `s1_answers` column and
every run also records the raw answer per id — type, value, probabilities, confidence, form,
model, time — for review UIs and audits: the measurement, persisted beside its collapse.

```ruby
result = ticket.update_measure(as: :thread) do |q, ticket|                 # the block also receives the record
  q.judge  :escalate,  "Is the customer asking for a human agent?"          # boolean column: written, collapsed
  q.choose :department, "Which team should handle this?", **ticket.store.departments   # string column: written
  q.judge  :prior_contact, "Has the customer contacted support about this before?"     # not a column: returned only
end
ticket.escalate                   # => true
result[:prior_contact]            # => #<S1::Answer::Noul 0.7>   the probability, still yours to route on
```

## assign_measure: collapse without saving

`update_measure` without the save: the collapse is assigned to the record and nothing else
happens. This is the one to call from inside a save (see [callbacks](#callbacks)). Alias
`assign_ask`.

```ruby
ticket.assign_measure { |q| q.choose :department, "Which team should handle this?", **DEPARTMENTS }
ticket.changed?   # => true
```

## update_measure_later: off the request thread

Same call, enqueued. The block runs now (it can read the record); the ask runs in
`S1::AskJob`, which retries `S1::TransientError` with ActiveJob's backoff (five attempts,
polynomially longer). Questions travel as their `to_h`; `as:`, `given:` and the form's keyword
arguments travel with them. Alias `update_ask_later`.

```ruby
ticket.update_measure_later(as: :thread) { |q| q.choose :department, "Which team should handle this?", **departments }
ticket.update_measure_later(:escalate, :severity)                             # the columns' own questions (measured_field)
```

## Callbacks and validations

**Measure into a column, validate the column.** `measure_on: :validation` fills the column in
`before_validation`; `validates` runs after it. So measure into a column and validate the
column with an ordinary validation — one call, the probability kept, the threshold in Rails'
own words:

```ruby
measured_field :plausible, "Is `story` a plausible account of losing the `item`?", measure_on: :validation
validates :plausible, numericality: { greater_than: 0.5, message: "doesn't sound like this item" }
```

**`validates … noul:` is for the gate whose measurement you do not want to keep**: no column,
one extra call, nothing stored. A validation that is a question. The state is the model's
default form when it has one, otherwise just the attribute. Nothing is persisted from the
answer — it only gates.

```ruby
validates :body, noul: "Is `body` a coherent support request?"
validates :body, noul: { with: "Does `body` contain a password, token, or another customer's data?", expect: false },
                 if: :will_save_change_to_body?
```

Options: `with` (the question; `noul: "…"` is shorthand), `expect` (default `true`),
`threshold`, `message`, plus the usual `if:` / `unless:` / `on:`. Each rule is one call, so
guard with `if: :will_save_change_to_…?` when the attribute rarely changes. The validator
works on any `ActiveModel` class; `S1::Measurable` is not required.

# Streams

## A relation: measure, collapse, or filter

Three things can happen to a measurement over a relation, and the verb says which:

| do | verb | record twin |
|---|---|---|
| **measure** — keep the distributions, write nothing | `measure_all(…)` → `{ record => Result }` | `measure` |
| **collapse** — write into the columns | `update_measure_all(…)` → `{ record => Result }` | `update_measure` |
| **filter** — keep the records a judge says yes to | `where_judged(q)` · `where_judged_not(q)` · `where_is(p)` · `where_is_not(p)` · `where_same_as(x)` | `judge?` · `is?` · `same_as?` |

`where_` is reserved for filtering, as in Rails; a choice or a score does not filter — it
buckets or ranks — so those live in `Enumerable` with a predicate: `group_by(&ψ.choose(…))`,
`sort_by(&ψ.score(…))`. `where_same_as` is a judge with a fixed question ("do `this` and `other`
describe the same thing?"), spelled for its most common case. All take `concurrency:` and `as:`;
the block also receives the record. `measure_select` / `measure_reject` / `measure_grep` are the
same filters in Enumerable's words, `ask_all` is `measure_all`, `update_ask_all` is
`update_measure_all`.

```ruby
SupportTicket.today.measure_all(:escalate, :severity, concurrency: 8)        # { ticket => Result }, nothing written
SupportTicket.where(department: nil).update_measure_all(:department, concurrency: 5)
SupportTicket.today.where_judged("Does the customer mention a competitor by name?", concurrency: 8)
Item.unclaimed.where_same_as(params[:Body], concurrency: 8)
```

## measure_all: a relation, measured

The relation's `measure`: one ask per record, `concurrency` in flight, `{ record => Result }`,
nothing written. Column names ask each column's declared question; a block builds the
questions and receives the record. Alias `ask_all`.

```ruby
SupportTicket.today.measure_all(:escalate, :severity, concurrency: 8)
SupportTicket.today.measure_all(concurrency: 8) { |q, ticket| q.judge :escalate, "Is the customer asking for a human agent?" }
```

## update_measure_all: a relation, collapsed

One `update_measure` per record in a relation, in `find_each` batches. `concurrency` is how
many asks are in flight at once; writes stay on the calling thread. The block receives the
record too, and runs on the ask's thread — keep `concurrency` under the connection pool if it
loads associations. Column names work here as well: `update_measure_all(:department)`. Alias
`update_ask_all`.

```ruby
SupportTicket.where(department: nil).update_measure_all(concurrency: 5) do |q, ticket|
  q.choose :department, "Which team should handle this?", **ticket.store.departments
end
# => { ticket => Result, ... }
```

The first failing ask raises; records already processed stay written.

## where_judged / where_is / where_same_as: a relation, filtered

The records in a relation for which a question is true (`where_judged`) or false
(`where_judged_not`). One call per record, `concurrency` at a time. `as:` picks the form;
anything else (`threshold:`, `true:` / `false:` clarification) goes to the judge.
`where_is` / `where_is_not` are the relation's `is?`: the phrase completes "Is this …?"
(`where_is_not("worth keeping")`). Aliases: `measure_select` / `measure_reject` (as Enumerable
would say it), `s1_select` / `s1_reject`.

```ruby
SupportTicket.today.where_judged("Does the customer mention a competitor by name?", concurrency: 8)
SupportTicket.open.where_judged_not("Is this resolved by the last agent message?", as: :thread, threshold: 0.8)
SupportTicket.today.where_is("an angry customer", concurrency: 8)
```

**The filters return relations** — `where(id: …)` after the judging, the idiom Rails uses when
something outside SQL chose the rows (`elasticsearch-model`'s `.records`, `searchkick`'s
`load: true`) — so `.destroy_all`, `.update_all`, `.count`, further `.where` continue in SQL. Be
clear about what that is not: the *filtering* ran in Ruby, one model call per record, before the
relation existed. Narrow with SQL first and judge the survivors; `concurrency:` on a method is the
tell that it is not a query.

**Context** for the judge comes per call — `where_judged("…", given: { text: body })` — or as a
scope up the chain: `Item.unclaimed.given(note: policy).where_judged_not("Is `this` worth keeping,
per `note`?")` (alias `against`) — the lens for every judgement down the chain. Backticked names
(`` `this` ``, `` `note` ``) are the path convention for pointing at a field; the model sees the
whole state either way, so use them when a question could be ambiguous, not by rule.

```ruby
Item.unclaimed.given(note: "we keep anything with an owner's name or over £20").where_is_not("worth keeping", concurrency: 8)
SupportTicket.today.given(policy: store.refund_policy).where_is("within policy", concurrency: 8)
```

**`where_same_as(other, concurrency:)`** (alias `measure_grep`) is the relation's `same_as?` /
`===`: the records that describe the same thing as `other`. `grep(ψ other)` is the same test,
one at a time.

```ruby
Item.unclaimed.where_same_as(params[:Body], concurrency: 8)      # which items is this text about?
Item.unclaimed.grep(ψ params[:Body])                              # same, sequential
```

## Predicates over relations

s1's predicates (`ψ.is`, `ψ.choose`, `ψ.score`, `ψ.judge` — see its *Collections* section)
work on records and relations directly, since a record converts to its default form.
`where_judged` / `where_is` / `update_measure_all` are the same idea with `concurrency:` and
the form choice built in.

```ruby
SupportTicket.today.select(&ψ.is("an angry customer"))                       # one call per record, sequential
SupportTicket.today.where_judged("Is the customer angry?", concurrency: 8)   # same, 8 in flight
SupportTicket.today.group_by(&ψ.choose("Which team?", enum: :department))    # measured_enum options and question resolve per record
SupportTicket.today.sum(&ψ.judge("the customer is angry"))                   # expected number of angry tickets, no threshold
SupportTicket.today.max_by(&ψ.score("How urgent?", "can wait", "today", "now"))
```

The knob is `given`: the lens every judgement down the chain is made against.

```ruby
SupportTicket.today.given(policy: store.refund_policy).where_is("within policy", concurrency: 8)
SupportTicket.today.select(&ψ.is("within `policy`", given: { policy: store.refund_policy }))   # the predicate form
```

# Plumbing

## Caching

With `c.cache = Rails.cache`, answers on a record are keyed by its `cache_key_with_version`,
form, form arguments and questions: an unchanged record never asks twice, and a write
(including `update_measure`) invalidates by bumping `updated_at`. New and dirty records bypass
the cache. A nested record changing does not bump the key — `touch: true` the association if
its changes should count.

## Cost and telemetry

Every completed call emits an `ask.s1` notification. `owner` is the record, `form` the form it
was measured through.

```ruby
ActiveSupport::Notifications.subscribe("ask.s1") do |event|
  result, request = event.payload.values_at(:result, :request)
  ApiCall.create!(owner: request.options[:owner], model: result.model, duration_ms: result.duration_ms, **result.usage)
end
```

## Testing

Point the provider at the Stub from s1; single-question calls are keyed by primitive name,
batches by question id. `update_measure_later` goes through ActiveJob, so `perform_enqueued_jobs`
runs it under the test adapter.

```ruby
S1.config.provider = S1::Providers::Stub.new(escalate: 0.9, department: :billing)      # a batch's ids
S1.config.provider = S1::Providers::Stub.new(noul: 0.9, choice: :billing, score: 2)     # single-question calls
S1.config.provider = S1::Providers::Stub.new { |req| { escalate: req.state[:body].include?("supervisor") ? 0.95 : 0.1 } }
```

## The boot check

The Railtie runs `S1::Measurable.verify!` after initialize when the app eager-loads
(production): every `measured_field` / `measured_enum` against the schema — a field that is
not a column raises, a kind that does not fit its column raises, positional score levels on an
integer column warn. Where the app does not eager-load, the spec under
[`measured_field`](#measured_field-how-a-column-is-measured) keeps it green.

## Explicit vs Rails primitive

Every form has an explicit spelling in s1; the Rails one is the same call with the plumbing
removed. `t` is a `SupportTicket`; `DEPTS` is `{ returns: "…", billing: "…" }`.

| you want | explicit | Rails primitive |
|---|---|---|
| a yes/no about a record | `S1::Subject.new({ subject: t.subject, body: t.body }).judge?("Is the customer angry?")` | `ticket.judge? "Is the customer angry?"` · `ticket.is? "angry"` · `(ψ ticket).is? "angry"` |
| the probability | `S1::Subject.new({ subject: t.subject, body: t.body }).judge("…").to_f` | `ticket.judge "…"` · `ticket.is "angry"` |
| one of a set | `S1::Subject.new({ … }).choose("Which team?", **DEPTS)` | `ticket.choose "Which team?", **DEPTS` · `delivery.choose "What happened?", enum: :status` |
| the option alone | `S1::Subject.new({ … }).choose("Which team?", **DEPTS).to_sym` | `ticket.choice "Which team?", **DEPTS` |
| several at once | `S1::Subject.new({ … }).measure { \|q\| … }` | `ticket.measure { \|q\| … }` |
| the answer in the row | `t.update!(department: S1::Subject.new({ … }).choose("Which team?", **DEPTS).to_s)` | `ticket.update_measure(:department)` |
| the answer in the row, inside a save | `before_validation { self.department = S1::Subject.new({ … }).choose(…).to_s }` | `before_validation { assign_measure(:department) }` · `measured_field :department, "…", **DEPTS, measure_on: :validation` |
| the answer in the row, later | a job class that rebuilds the state and the questions | `ticket.update_measure_later { \|q\| q.choose :department }` |
| a column's question, once | the string, wherever it is asked | `measured_field :escalate, "…"` · `measured_enum :department, "…", **DEPTS` |
| filter a relation | `tickets.select { \|t\| S1::Subject.new({ … }).judge?("…") }` | `SupportTicket.today.where_judged("…", concurrency: 8)` · `SupportTicket.today.select(&ψ.is("…"))` |
| bucket a relation | `tickets.group_by { \|t\| S1::Subject.new({ … }).choose("…", **DEPTS).to_sym }` | `SupportTicket.today.group_by(&ψ.choose("…", enum: :department))` |
| measure a relation, write nothing | `tickets.to_h { \|t\| [t, S1::Subject.new({ … }).measure { \|q\| … }] }` | `SupportTicket.today.measure_all(:escalate, concurrency: 8)` |
| backfill a column | `tickets.each { \|t\| t.update!(department: …) }` | `SupportTicket.where(department: nil).update_measure_all(:department, concurrency: 5)` |
| against a preference | `S1::Subject.new({ this: { … }, policy: p }).judge?("… per \`policy\`")` | `ticket.given(policy: p).is? "… per \`policy\`"` · `Ticket.open.given(policy: p).where_is("…")` · `measured_against { { policy: … } }` |
| the same thing? | `S1::Subject.new({ this: a.attributes, other: b.attributes }).judge?("Do \`this\` and \`other\` describe the same thing?")` | `candidates.any?(ψ vendor)` · `case other when (ψ vendor)` · `Vendor.where(…).where_same_as(vendor)` |
| gate a save | `validate { errors.add(:body, :invalid) unless S1::Subject.new({ body: body }).judge?("…") }` | `validates :body, noul: "…"` |
| keep the measurement | write `probabilities` somewhere yourself | a `float` column, or an `s1_answers` json column |

## Dictionary and aliases

On top of s1's vocabulary (state, stream, collapse, noul, choice, score, measure, criteria,
threshold, predicate, given):

| term | meaning | also |
|---|---|---|
| **form** | how a record is measurable, under a name — the facts: `measurable_as :name do … end`; `:default` when unnamed | `s1_state` |
| **lens** | what a record is judged against: `measured_against { … }` declared, `given:` / `.given(…)` per call, merged over it; the state becomes `{ this: facts, **lens }` | `measured_given`; `against` |
| **ψ on a record** | `(ψ record)` is `record.as_measurable`; `(ψ record, as: :thread, last: 10)` a named form with arguments — a record defines `to_s1`, so `S1.to_state` and every predicate convert it | `S1.to_state(record, as: …)` without the symbol; `as` |
| **given** on a record or a relation | judged against context, for one call: the default form becomes `this`, the context sits beside it — `ticket.given(policy: p).is? "within \`policy\`"`; on a relation, a scope carrying the lens for every judgement down the chain — `Item.unclaimed.given(note: p).where_is_not("…")` | `against`; `measured_against`, for every call |
| **judge / judge?** on a record | the primitives, delegated to the default form; no `?` keeps the probability, `?` collapses | `noul` / `noul?`, `ask?`; `is` / `is?` complete "Is this …?" |
| **choose / choice**, **score / level** on a record | the other kinds: the verb measures (`Answer::Choice` / `Answer::Score`), the noun collapses (the option, a Symbol; the level, an `S1::Level` — the label, ordered by position) | — |
| **measure** on a record | the plural: several questions, one call, independent answers | `ask`, `batch`, `ask_about` |
| **measured_field** | how a column is measured: its question, and levels / options; the kind follows the column (`s1_kind`); a score on an integer column takes `{ level => integer }`; `measure_on:` puts it on the lifecycle (`:validation` sync, `:create` / `:save` / `:update` async) | `s1_field`, `measured_attribute`, `measurable_field`; `measured_enum` is the choice case with a real enum; `S1::Measurable.verify!` checks them all against the schema |
| **measured_enum** | an enum that is also a choice question: the question plus a description per value | `s1_enum`, `choice_enum`; `enum: :name` borrows its options for another question |
| **update_measure** | measure, collapse column-named answers into the row (coerced by column type — the type is the collapse policy), `save!` | `update_ask` |
| **assign_measure** | the same collapse, assigned and not saved — for inside a save | `assign_ask` |
| **update_measure_later** | the same, enqueued in `S1::AskJob` | `update_ask_later` |
| **measure_all** | the relation's `measure`: `{ record => Result }`, nothing written | `ask_all`; `update_measure_all` is the same followed by the collapse |
| **update_measure_all** | the same over a relation, `concurrency` asks in flight, `{ record => Result }` | `update_ask_all` |
| **where_judged** | the records in a relation for which a question is judged true — the relation's `judge?`; `given:` for context | `measure_select`, `s1_select`; `where_judged_not` (`measure_reject`, `s1_reject`) for false |
| **where_is** | the relation's `is?`: `where_is("…")` / `where_is_not` take the phrase that completes "Is this …?" | `where_judged("Is this …?")` |
| **where_same_as** | the records that describe the same thing as `other` — the relation's `same_as?` / `===`, with `concurrency:` | `measure_grep`; `grep(ψ other)` is the sequential form |
| **s1_answers** | optional json column that keeps every raw answer per id — the measurement, persisted beside its collapse | — |
| **noul:** | the validator: `validates :attr, noul: "…"` — a judgement that gates a save, nothing stored | `with:` / `expect:` / `threshold:` / `message:` |
| **ask.s1** | the `ActiveSupport::Notifications` event every call emits (`result`, `request`; `request.options[:owner]` is the record) | `S1.on_result` in s1 |
| **cache** | `c.cache = Rails.cache`: answers keyed by record version, form, arguments and questions | — |

Aliases are plain Ruby `alias`es, so a class's own method with the same name always wins.

# Usage scenarios

Each is free text (or two records) in, a boolean or enum out, inside a request or a save —
where a regex can't and a text-generating model is the wrong tool. Where a String or Hash is
the receiver, `c.primitives = true` is on.

## Models

### Checking another model's output

An LLM extracts an order number and drafts a refund recommendation from an email. Asking the
same model whether it did well is grading its own work; S1 is a different model answering a
narrow question.

```ruby
class RefundRequest < ApplicationRecord
  include S1::Measurable
  measurable_as(:grounding) { { email: email_body, order_number: order_number, recommendation: recommendation, approve: approve } }

  validate do
    g = as_measurable(:grounding).measure do |q|
      q.judge :order_in_email,  "Does `order_number` appear in `email`?"
      q.judge :reason_supports, "Does `recommendation` justify `approve` being true?"
    end
    errors.add(:order_number,   :not_in_source)  unless g.true?(:order_in_email)
    errors.add(:recommendation, :does_not_support) if approve && !g.true?(:reason_supports)
  end
end
```

### Uniqueness that `uniqueness: true` can't see

"Acme Inc" and "ACME, Incorporated" are one vendor; a regex compares strings, `===` compares
what they describe. Narrow with SQL, then ask about the survivors (one call each).

```ruby
validate do
  candidates = Vendor.where(account: account).where("similarity(name, ?) > 0.3", name)
  errors.add(:base, :duplicate) if candidates.any?(ψ self)      # Subject#=== is same_as?
end
```

### Prose configuration that has to be coherent

A store owner writes the return policy customers read; the checkout enforces an integer. The
prose says "two weeks", "a fortnight", "within the month", or nothing about time at all, and
may say two things ("30 days, 60 for members") — there is no number to parse out and compare.
The check is whether the two agree, not what the number is.

```ruby
class Store < ApplicationRecord
  # refund_policy:      "Returns accepted within two weeks of delivery; final-sale items excluded."  (textarea, shown to customers)
  # return_window_days: 30                                                                            (integer, enforced at checkout)
  validate do
    errors.add(:refund_policy, "promises a different return window than #{return_window_days} days") if
      { policy: refund_policy, window_days: return_window_days }
        .judge?("Does `policy` state a return window other than `window_days` days?")
  end
end
```

### Content that must never be saved

The answer isn't data to keep; it's a gate. A failing `noul:` leaves the record unsaved and
the user sees a normal validation error.

```ruby
class Reply < ApplicationRecord
  validates :body, noul: { with: "Does `body` contain a password, token, or another customer's data?", expect: false },
                   if: :will_save_change_to_body?
end
```

## Callbacks

### Enriching on save

Sync in `before_validation` / `before_save` when the columns must exist at insert and the save
can absorb ~400ms; async via `after_commit` + `update_measure_later` when it can't.
`measure_on:` is the declared spelling of both.

```ruby
class SupportTicket < ApplicationRecord
  before_validation -> { assign_measure { |q| q.choose :department, "Which team should handle this?", **DEPARTMENTS } },
                    if: :will_save_change_to_body?
  validates :department, presence: true

  after_create_commit { update_measure_later(as: :thread) { |q| q.score :severity, "How severe is the issue?", "Cosmetic", "Degraded", "Blocking" } }
end
```

### Re-measuring on every event

State changes per message; S1 is cheap enough to measure again each time, and the collapse
lands in a column the UI already renders.

```ruby
class Message < ApplicationRecord
  belongs_to :ticket, touch: true
  after_create_commit { ticket.update_measure(as: :thread) { |q| q.judge :escalate, "Is the customer asking for a human agent?" } }
end
```

## Controllers and webhooks

### Free-text replies that must become state

A courier texts back "left with neighbour" / "nobody home, tried twice" / "address doesn't
exist".

```ruby
def create   # inbound SMS webhook
  delivery.update!(status: params[:Body].choice("What is the sender reporting?",
    delivered: "Handed over or left somewhere", attempted: "Tried, no one there", undeliverable: "Bad address"))
end
```

Or keep the options with the column, via `measured_enum`:

```ruby
class Delivery < ApplicationRecord
  include S1::Measurable
  measured_enum :status, "What is the sender reporting?",
          delivered: "Handed over or left somewhere", attempted: "Tried, no one there", undeliverable: "Bad address"
  measurable_as(:sms) { |body:| { message: body } }
end

def create
  delivery.update_measure(:status, as: :sms, body: params[:Body])
end

# or, when the state isn't the record:
delivery.update!(status: params[:Body].choice("What is the sender reporting?", **Delivery.s1_enum(:status)))
```

### Intent dispatch

One endpoint for replies of any kind; `choice` decides the action.

```ruby
def create
  case params[:body].choice("What does the sender want?",
                            cancel: "Cancel or stop", reschedule: "Change a time", question: "Asks something else")
  when :cancel     then appointment.cancel!
  when :reschedule then redirect_to new_reschedule_path(appointment)
  else                  Inbox.hold(params[:body])
  end
end
```

### Routing by confidence

Every answer carries `confident?`. The convention at the edge: act when confident, hand off
when not — collapse late.

```ruby
answer = ticket.choose("Which team?", **departments)
answer.confident? ? ticket.assign!(answer.to_sym) : ticket.hold_for_triage!
```

### Locale from content

`Accept-Language` describes the browser, not the message.

```ruby
around_action do |_, action|
  I18n.with_locale(params[:message].choice("Which language is this written in?", en: "English", es: "Spanish"), &action)
end
```

## Mail

### Routing inbound mail by content

`ActionMailbox` routes on headers; a lambda can route on what the mail says. Then drop
auto-replies before they open tickets.

```ruby
class ApplicationMailbox < ActionMailbox::Base
  routing ->(inbound) { inbound.mail.decoded.judge?("Is this a refund or return request?") } => :refunds
  routing :all => :support
end

class SupportMailbox < ApplicationMailbox
  before_processing { bounced! if mail.decoded.judge?("Is this an automated or out-of-office reply?") }
end
```

### Guarding outbound mail

For mail assembled from templates, with no record to validate:

```ruby
class OutboundGuard
  def self.delivering_email(mail)
    mail.perform_deliveries = false if mail.body.decoded.judge?("Does this message contain a password, token, or another customer's data?")
  end
end
ActionMailer::Base.register_interceptor(OutboundGuard)
```

## Batch and console

### Backfilling a column

```ruby
SupportTicket.where(department: nil).update_measure_all(concurrency: 5) do |q, ticket|
  q.choose :department, "Which team should handle this?", **ticket.store.departments
end
SupportTicket.where(department: nil).update_measure_all(:department, concurrency: 5)   # the column's own question
```

### Ad-hoc triage

```ruby
SupportTicket.today.where_judged("Does the customer mention a competitor by name?", concurrency: 8)
SupportTicket.today.sum(&ψ.judge("the customer is threatening a chargeback"))   # expected count, nothing collapsed

S1.subject = SupportTicket.last.as_measurable(:thread)   # console: then ask with no receiver (Kernel in c.primitives)
judge? "Is the customer threatening a chargeback?"
```

## Development

`bin/setup`, then `bundle exec rake` (specs on in-memory SQLite + rubocop). The Gemfile points
`s1` at `../typesafe-ruby`.

## License

MIT.
