# frozen_string_literal: true

require 'test_helper'

class ActiveLearnerTest < StateMachinesTest
  # Legacy object under learning: exposes ONLY event methods. Its state is
  # private and can solely be observed through the values events return.
  #
  # A keypad lock that opens after the code :up, :up, :down is entered.
  # Any wrong key resets the code; once open it stays open.
  class LegacyCodeLock
    CODE = %i[up up down].freeze

    def initialize
      @progress = 0
      @open = false
    end

    def press(direction)
      return :already_open if @open

      if direction == CODE[@progress]
        @progress += 1
        if @progress == CODE.length
          @open = true
          :unlocked
        else
          :tick
        end
      else
        @progress = 0
        :reset
      end
    end
  end

  # In-process equivalence oracle: exhaustively compares the hypothesis with
  # a fresh instance of the legacy object over every input sequence up to a
  # depth derived from the hypothesis size. Returns the first distinguishing
  # sequence it finds, or nil when the hypothesis is behaviourally equal.
  class ExhaustiveOracle
    def initialize(sul_factory, inputs, slack: 2)
      @sul_factory = sul_factory
      @inputs = inputs
      @slack = slack
    end

    def call(hypothesis)
      max_depth = hypothesis.states.size + @slack
      queue = [[]]
      until queue.empty?
        sequence = queue.shift
        sul = @sul_factory.call
        expected = sequence.map { |input| sul.press(input) }
        return sequence if hypothesis.run(sequence) != expected

        queue.concat(@inputs.map { |input| sequence + [input] }) if sequence.length < max_depth
      end
      nil
    end
  end

  # Oracle that injects one scripted counterexample (if it still exposes a
  # divergence) before delegating to the exhaustive oracle, simulating a
  # teacher that spots a single mistake.
  class ScriptedOracle
    attr_reader :counterexamples_given

    def initialize(counterexample, sul_factory, fallback)
      @counterexample = counterexample
      @sul_factory = sul_factory
      @fallback = fallback
      @counterexamples_given = 0
    end

    def call(hypothesis)
      if @counterexamples_given.zero? && hypothesis.run(@counterexample) != run_on_fresh_sul
        @counterexamples_given += 1
        return @counterexample
      end

      @fallback.call(hypothesis)
    end

    private

    def run_on_fresh_sul
      sul = @sul_factory.call
      @counterexample.map { |input| sul.press(input) }
    end
  end

  INPUTS = %i[up down].freeze
  LOCK_STATES = 4 # progress 0..2 plus the open state

  def setup
    @sul = nil
    reset = -> { @sul = LegacyCodeLock.new }
    step = ->(event) { @sul.press(event) }
    @callbacks = { inputs: INPUTS, reset: reset, step: step }
    @exhaustive_oracle = ExhaustiveOracle.new(-> { LegacyCodeLock.new }, INPUTS)
  end

  def test_learns_model_equivalent_to_legacy_object
    learner = StateMachines::ActiveLearner.new(**@callbacks, equivalence: @exhaustive_oracle)

    assert_same learner, learner.learn
    assert_equal :equivalent, learner.stop_reason
    assert_equal LOCK_STATES, learner.hypothesis.states.size
    # The first hypothesis merges the two "code in progress" states, so the
    # oracle must hand back counterexamples before convergence.
    assert_operator learner.statistics.equivalence_queries, :>=, 2
    assert_operator learner.statistics.membership_queries, :>, 0
    assert_equal learner.statistics.membership_queries, learner.statistics.resets
    assert_operator learner.statistics.input_symbols, :>=, learner.statistics.membership_queries
  end

  def test_learned_model_reproduces_legacy_outputs_on_fresh_sequences
    learner = StateMachines::ActiveLearner.new(**@callbacks, equivalence: @exhaustive_oracle)
    learner.learn

    random = Random.new(42)
    sequence = Array.new(100) { INPUTS[random.rand(INPUTS.size)] }
    sul = LegacyCodeLock.new
    expected = sequence.map { |event| sul.press(event) }
    assert_equal expected, learner.hypothesis.run(sequence)
  end

  def test_counterexample_is_generalized_into_model_not_hardcoded
    counterexample = %i[up up down]
    oracle = ScriptedOracle.new(counterexample, -> { LegacyCodeLock.new }, @exhaustive_oracle)
    learner = StateMachines::ActiveLearner.new(**@callbacks, equivalence: oracle)
    learner.learn

    assert_equal 1, oracle.counterexamples_given
    assert_equal :equivalent, learner.stop_reason
    assert_operator learner.statistics.equivalence_queries, :>=, 2
    # The counterexample is folded into the observation table and the model
    # is re-derived globally: the result is the minimal 4-state machine, not
    # a lookup tree memorizing the 3-event counterexample (which alone would
    # already occupy a chain of 4 states before modelling anything else).
    assert_equal LOCK_STATES, learner.hypothesis.states.size
    # And the corrected model gets the counterexample sequence itself right.
    assert_equal %i[tick tick unlocked], learner.hypothesis.run(counterexample)
  end

  def test_stops_with_reason_when_equivalence_budget_is_exhausted
    stubborn_oracle = ->(_hypothesis) { [:up] }
    learner = StateMachines::ActiveLearner.new(
      **@callbacks,
      equivalence: stubborn_oracle,
      max_equivalence_queries: 3
    )
    learner.learn

    assert_equal :max_equivalence_queries, learner.stop_reason
    assert_equal 3, learner.statistics.equivalence_queries
  end

  def test_stops_with_reason_when_membership_budget_is_exhausted
    learner = StateMachines::ActiveLearner.new(
      **@callbacks,
      equivalence: @exhaustive_oracle,
      max_membership_queries: 2
    )
    learner.learn

    assert_equal :max_membership_queries, learner.stop_reason
    assert_equal 2, learner.statistics.membership_queries
  end

  def test_hypothesis_exposes_mealy_structure_and_dot_documentation
    learner = StateMachines::ActiveLearner.new(**@callbacks, equivalence: @exhaustive_oracle)
    learner.learn
    machine = learner.hypothesis

    assert_equal INPUTS, machine.inputs
    assert_includes machine.states, machine.initial_state
    machine.states.each do |state|
      INPUTS.each do |input|
        assert_includes machine.states, machine.next_state(state, input)
        refute_nil machine.output(state, input)
      end
    end

    dot = machine.to_dot
    assert_match(/digraph mealy/, dot)
    assert_match(%r{label="down / unlocked"}, dot)
  end
end
