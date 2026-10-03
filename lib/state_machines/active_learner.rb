# frozen_string_literal: true

require 'state_machines/mealy_machine'

module StateMachines
  # Active automata learner (L* adapted to Mealy machines).
  #
  # The learner reverse-engineers a finite Mealy model of a "system under
  # learning" that only exposes an event interface. The caller supplies three
  # callbacks, all of which may live in the same process:
  #
  # * +reset+       - returns the system to its initial state.
  # * +step+        - feeds one input event to the system and returns the
  #                   observable output of that event.
  # * +equivalence+ - receives the current hypothesis (a MealyMachine) and
  #                   returns +nil+ when it accepts the model, or a
  #                   counterexample: a sequence of inputs on which the
  #                   hypothesis and the real system disagree.
  #
  # Counterexamples are folded back into the learner's observation table (by
  # adding their suffixes as distinguishing experiments), so the next
  # hypothesis is a corrected global model - the counterexample itself is
  # never hardcoded into the machine.
  #
  # After #learn returns, #hypothesis holds the learned MealyMachine,
  # #statistics exposes how many queries were needed and #stop_reason tells
  # why learning stopped (:equivalent, :max_membership_queries or
  # :max_equivalence_queries).
  #
  # Example:
  #
  #   learner = StateMachines::ActiveLearner.new(
  #     inputs: %i[insert_coin push],
  #     reset: -> { @sul = LegacyGate.new },
  #     step: ->(event) { @sul.send(event) },
  #     equivalence: ->(hypothesis) { MyOracle.check(hypothesis) }
  #   )
  #   learner.learn
  #   puts learner.hypothesis.to_dot
  class ActiveLearner
    Statistics = Struct.new(:membership_queries, :equivalence_queries, :resets, :input_symbols, keyword_init: true)

    attr_reader :inputs, :statistics, :hypothesis, :stop_reason

    def initialize(inputs:, reset:, step:, equivalence:, max_membership_queries: 100_000, max_equivalence_queries: 1_000)
      @inputs = inputs.dup.freeze
      @reset_callback = reset
      @step_callback = step
      @equivalence_callback = equivalence
      @max_membership_queries = max_membership_queries
      @max_equivalence_queries = max_equivalence_queries
      @statistics = Statistics.new(membership_queries: 0, equivalence_queries: 0, resets: 0, input_symbols: 0)
      @output_cache = {}
      @stop_reason = nil
      @hypothesis = nil
    end

    def learn
      catch(:membership_budget_exceeded) do
        learn_loop
        return self
      end
      @stop_reason = :max_membership_queries
      self
    end

    private

    def learn_loop
      access_sequences = [[]]
      suffixes = @inputs.map { |input| [input] }

      loop do
        refine_table(access_sequences, suffixes)
        @hypothesis = build_hypothesis(access_sequences, suffixes)

        @statistics.equivalence_queries += 1
        counterexample = @equivalence_callback.call(@hypothesis)
        if counterexample.nil?
          @stop_reason = :equivalent
          return
        elsif @statistics.equivalence_queries >= @max_equivalence_queries
          @stop_reason = :max_equivalence_queries
          return
        end

        # Fold the counterexample into the table: every suffix becomes a
        # distinguishing experiment, forcing the next hypothesis to explain
        # the divergence instead of memorizing this one sequence.
        suffixes |= counterexample.each_index.map { |index| counterexample[index..] }
      end
    end

    def refine_table(access_sequences, suffixes)
      loop do
        next if close(access_sequences, suffixes)
        break unless make_consistent(access_sequences, suffixes)
      end
    end

    # Ensures every one-step extension of an access sequence is represented
    # by some access sequence already in the table.
    def close(access_sequences, suffixes)
      known_rows = access_sequences.map { |sequence| row(sequence, suffixes) }
      access_sequences.each do |sequence|
        @inputs.each do |input|
          extension = sequence + [input]
          next if known_rows.include?(row(extension, suffixes))

          access_sequences << extension
          return true
        end
      end
      false
    end

    # Ensures access sequences with identical rows keep identical rows after
    # any input; otherwise the offending input plus the suffix exposing the
    # difference becomes a new distinguishing experiment.
    def make_consistent(access_sequences, suffixes)
      access_sequences.group_by { |sequence| row(sequence, suffixes) }.each_value do |group|
        first, *rest = group
        rest.each do |other|
          @inputs.each do |input|
            next if row(first + [input], suffixes) == row(other + [input], suffixes)

            exposing = suffixes.find { |suffix| cell(first + [input], suffix) != cell(other + [input], suffix) }
            suffixes << [input] + exposing
            return true
          end
        end
      end
      false
    end

    def build_hypothesis(access_sequences, suffixes)
      rows = access_sequences.to_h { |sequence| [sequence, row(sequence, suffixes)] }
      state_ids = rows.values.uniq.each_with_index.to_h { |table_row, index| [table_row, :"q#{index}"] }

      transitions = {}
      access_sequences.each do |sequence|
        from = state_ids[rows[sequence]]
        edges = @inputs.to_h do |input|
          [input, [cell(sequence, [input]).first, state_ids[row(sequence + [input], suffixes)]]]
        end
        transitions[from] = edges
      end

      MealyMachine.new(
        states: state_ids.values,
        inputs: @inputs,
        initial_state: state_ids[rows[[]]],
        transitions: transitions
      )
    end

    def row(sequence, suffixes)
      suffixes.map { |suffix| cell(sequence, suffix) }
    end

    def cell(sequence, suffix)
      output_query(sequence + suffix).last(suffix.length)
    end

    # Runs one membership query against the system: reset, then feed the
    # whole sequence, collecting one output per input. Results are cached so
    # repeated table cells never hit the system twice.
    def output_query(sequence)
      @output_cache.fetch(sequence) do
        throw :membership_budget_exceeded if @statistics.membership_queries >= @max_membership_queries

        @statistics.membership_queries += 1
        @statistics.resets += 1
        @statistics.input_symbols += sequence.length
        @reset_callback.call
        @output_cache[sequence] = sequence.map { |input| @step_callback.call(input) }
      end
    end
  end
end
