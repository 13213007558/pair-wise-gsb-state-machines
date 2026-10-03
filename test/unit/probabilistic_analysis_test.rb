# frozen_string_literal: true

require 'test_helper'

class ProbabilisticAnalysisTest < StateMachinesTest
  def setup
    @klass = Class.new
  end

  # Four-state model with one bad closed loop:
  #
  #   start --0.4--> done        start --0.6--> mid
  #   mid   --0.5--> done        mid   --0.5--> trap
  #   trap  --1.0--> trap (bad closed loop, never reaches done)
  def build_bad_loop_machine
    machine = StateMachines::Machine.new(@klass)
    machine.event :advance do
      transition start: :done, probability: 0.4, cost: 2
      transition start: :mid, probability: 0.6, cost: 1
    end
    machine.event :resolve do
      transition mid: :done, probability: 0.5, cost: 1
      transition mid: :trap, probability: 0.5, cost: 1
    end
    machine.event :spin do
      transition trap: :trap, probability: 1.0, cost: 3
    end
    machine
  end

  # Fully absorbing model:
  #
  #   a --0.5(cost 2)--> b    a --0.5(cost 4)--> c
  #   b --0.25(cost 1)--> a   b --0.75(cost 3)--> c
  def build_absorbing_machine
    machine = StateMachines::Machine.new(@klass)
    machine.event :first do
      transition a: :b, probability: 0.5, cost: 2
      transition a: :c, probability: 0.5, cost: 4
    end
    machine.event :second do
      transition b: :a, probability: 0.25, cost: 1
      transition b: :c, probability: 0.75, cost: 3
    end
    machine
  end

  def test_should_store_probability_and_cost_on_branches
    machine = build_bad_loop_machine
    branch = machine.events[:advance].branches.first

    assert_in_delta(0.4, branch.probability)
    assert_equal 2, branch.cost
  end

  def test_should_default_branch_probability_and_cost_to_nil
    machine = StateMachines::Machine.new(@klass)
    machine.event(:ignite) { transition parked: :idling }
    branch = machine.events[:ignite].branches.first

    assert_nil branch.probability
    assert_nil branch.cost
  end

  def test_should_check_probability_sum_for_each_state
    analysis = StateMachines::ProbabilisticAnalysis.new(build_bad_loop_machine, target: :done)

    assert_in_delta(1.0, analysis.probability_sums[:start])
    assert_in_delta(1.0, analysis.probability_sums[:mid])
    assert_in_delta(1.0, analysis.probability_sums[:trap])
    refute analysis.probability_sums.key?(:done)
  end

  def test_should_raise_when_probabilities_do_not_sum_to_one
    machine = StateMachines::Machine.new(@klass)
    machine.event :advance do
      transition start: :done, probability: 0.3
      transition start: :mid, probability: 0.3
    end

    exception = assert_raises(ArgumentError) { StateMachines::ProbabilisticAnalysis.new(machine, target: :done) }
    assert_match(/:start/, exception.message)
    assert_match(/sum to 1/, exception.message)
  end

  def test_should_raise_for_invalid_probability
    machine = StateMachines::Machine.new(@klass)
    machine.event(:advance) { transition start: :done, probability: 1.5 }

    assert_raises(ArgumentError) { StateMachines::ProbabilisticAnalysis.new(machine, target: :done) }
  end

  def test_should_raise_for_negative_cost
    machine = StateMachines::Machine.new(@klass)
    machine.event(:advance) { transition start: :done, probability: 1.0, cost: -1 }

    assert_raises(ArgumentError) { StateMachines::ProbabilisticAnalysis.new(machine, target: :done) }
  end

  def test_should_raise_for_unknown_target
    machine = build_bad_loop_machine

    assert_raises(ArgumentError) { StateMachines::ProbabilisticAnalysis.new(machine, target: :unknown) }
  end

  # Item-by-item verification of the four-state bad-loop model
  def test_bad_loop_absorption_probabilities
    analysis = StateMachines::ProbabilisticAnalysis.new(build_bad_loop_machine, target: :done)

    assert_in_delta(1.0, analysis.absorption_probability(:done))
    assert_in_delta(0.7, analysis.absorption_probability(:start))
    assert_in_delta(0.5, analysis.absorption_probability(:mid))
    assert_in_delta(0.0, analysis.absorption_probability(:trap))
  end

  def test_bad_loop_absorption_probabilities_are_not_discarded
    analysis = StateMachines::ProbabilisticAnalysis.new(build_bad_loop_machine, target: :done)

    assert_equal %i[done mid start trap], analysis.absorption_probabilities.keys.compact.sort
    analysis.absorption_probabilities.each_value { |probability| assert_kind_of Float, probability }
  end

  def test_bad_loop_expected_costs_are_infinite
    analysis = StateMachines::ProbabilisticAnalysis.new(build_bad_loop_machine, target: :done)

    assert_equal 0.0, analysis.expected_cost(:done)
    assert_equal Float::INFINITY, analysis.expected_cost(:start)
    assert_equal Float::INFINITY, analysis.expected_cost(:mid)
    assert_equal Float::INFINITY, analysis.expected_cost(:trap)
  end

  def test_bad_loop_expected_times_are_infinite
    analysis = StateMachines::ProbabilisticAnalysis.new(build_bad_loop_machine, target: :done)

    assert_equal 0.0, analysis.expected_time(:done)
    assert_equal Float::INFINITY, analysis.expected_time(:start)
    assert_equal Float::INFINITY, analysis.expected_time(:mid)
    assert_equal Float::INFINITY, analysis.expected_time(:trap)
  end

  def test_absorbing_model_absorption_probabilities
    analysis = StateMachines::ProbabilisticAnalysis.new(build_absorbing_machine, target: :c)

    assert_in_delta(1.0, analysis.absorption_probability(:a))
    assert_in_delta(1.0, analysis.absorption_probability(:b))
    assert_in_delta(1.0, analysis.absorption_probability(:c))
  end

  def test_absorbing_model_expected_costs
    analysis = StateMachines::ProbabilisticAnalysis.new(build_absorbing_machine, target: :c)

    assert_in_delta(34.0 / 7, analysis.expected_cost(:a))
    assert_in_delta(26.0 / 7, analysis.expected_cost(:b))
    assert_in_delta(0.0, analysis.expected_cost(:c))
  end

  def test_absorbing_model_expected_times
    analysis = StateMachines::ProbabilisticAnalysis.new(build_absorbing_machine, target: :c)

    assert_in_delta(12.0 / 7, analysis.expected_time(:a))
    assert_in_delta(10.0 / 7, analysis.expected_time(:b))
    assert_in_delta(0.0, analysis.expected_time(:c))
  end

  def test_should_default_transition_cost_to_one
    machine = StateMachines::Machine.new(@klass)
    machine.event(:finish) { transition running: :done, probability: 1.0 }
    analysis = StateMachines::ProbabilisticAnalysis.new(machine, target: :done)

    assert_in_delta(1.0, analysis.expected_cost(:running))
    assert_in_delta(1.0, analysis.expected_time(:running))
  end

  def test_should_expand_loopback_transitions
    machine = StateMachines::Machine.new(@klass)
    machine.event :retry do
      transition a: :a, probability: 0.5, cost: 1
      transition a: :done, probability: 0.5, cost: 1
    end
    analysis = StateMachines::ProbabilisticAnalysis.new(machine, target: :done)

    assert_in_delta(1.0, analysis.absorption_probability(:a))
    assert_in_delta(2.0, analysis.expected_time(:a))
  end

  def test_should_expand_all_matcher_transitions
    machine = StateMachines::Machine.new(@klass)
    machine.state :a
    machine.state :b
    machine.event(:finish) { transition all - :done => :done, probability: 1.0 }
    analysis = StateMachines::ProbabilisticAnalysis.new(machine, target: :done)

    assert_in_delta(1.0, analysis.absorption_probability(:a))
    assert_in_delta(1.0, analysis.absorption_probability(:b))
    assert_in_delta(1.0, analysis.expected_cost(:a))
  end

  def test_should_be_accessible_through_machine
    machine = build_bad_loop_machine
    analysis = machine.probabilistic_analysis(:done)

    assert_instance_of StateMachines::ProbabilisticAnalysis, analysis
    assert_in_delta(0.7, analysis.absorption_probability(:start))
  end
end
