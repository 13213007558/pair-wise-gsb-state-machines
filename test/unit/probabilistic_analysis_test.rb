# frozen_string_literal: true

require 'test_helper'

class ProbabilisticAnalysisTest < StateMachinesTest
  def setup
    @machine = StateMachines::Machine.new(Class.new)
    @machine.state :start, :spin_a, :spin_b, :done
    @analysis = StateMachines::ProbabilisticAnalysis.new(@machine)
  end

  # Four-state model with one bad closed loop:
  #
  #   start  --0.5--> done     (cost 2)
  #   start  --0.5--> spin_a   (cost 1)
  #   spin_a --1.0--> spin_b   (cost 1)
  #   spin_b --1.0--> spin_a   (cost 1)   <- closed loop, never reaches done
  def build_bad_loop_model
    @analysis.branch from: :start, to: :done, probability: 0.5, cost: 2
    @analysis.branch from: :start, to: :spin_a, probability: 0.5
    @analysis.branch from: :spin_a, to: :spin_b, probability: 1.0
    @analysis.branch from: :spin_b, to: :spin_a, probability: 1.0
  end

  def test_should_track_machine_and_branches
    build_bad_loop_model

    assert_equal @machine, @analysis.machine
    assert_equal 4, @analysis.branches.length
    assert_equal({ from: :start, to: :done, probability: 0.5, cost: 2.0 }, @analysis.branches.first)
  end

  def test_should_sum_outgoing_probabilities_per_state
    build_bad_loop_model

    assert_equal({ start: 1.0, spin_a: 1.0, spin_b: 1.0 }, @analysis.outgoing_probability_sums)
  end

  def test_should_compute_absorption_probabilities_despite_bad_loop
    build_bad_loop_model

    probabilities = @analysis.absorption_probabilities(to: :done)
    assert_in_delta 0.5, probabilities[:start]
    assert_in_delta 0.0, probabilities[:spin_a]
    assert_in_delta 0.0, probabilities[:spin_b]
    assert_in_delta 1.0, probabilities[:done]
  end

  def test_should_report_infinite_expected_cost_for_states_that_can_be_trapped
    build_bad_loop_model

    costs = @analysis.expected_costs(to: :done)
    assert_equal Float::INFINITY, costs[:start]
    assert_equal Float::INFINITY, costs[:spin_a]
    assert_equal Float::INFINITY, costs[:spin_b]
    assert_equal 0.0, costs[:done]
  end

  def test_should_not_discard_absorption_probabilities_when_expected_costs_are_infinite
    build_bad_loop_model

    costs = @analysis.expected_costs(to: :done)
    probabilities = @analysis.absorption_probabilities(to: :done)

    assert_equal Float::INFINITY, costs[:start]
    assert_in_delta 0.5, probabilities[:start]
  end

  def test_should_compute_finite_expected_costs_for_fully_absorbing_model
    machine = StateMachines::Machine.new(Class.new)
    machine.state :a, :b, :c
    analysis = StateMachines::ProbabilisticAnalysis.new(machine)
    analysis.branch from: :a, to: :a, probability: 0.5, cost: 1
    analysis.branch from: :a, to: :b, probability: 0.5, cost: 3
    analysis.branch from: :b, to: :c, probability: 1.0, cost: 2

    probabilities = analysis.absorption_probabilities(to: :c)
    probabilities.each_value { |probability| assert_in_delta 1.0, probability }

    costs = analysis.expected_costs(to: :c)
    assert_in_delta 6.0, costs[:a]
    assert_in_delta 2.0, costs[:b]
    assert_in_delta 0.0, costs[:c]
  end

  def test_should_mix_finite_and_infinite_expected_costs_in_one_model
    machine = StateMachines::Machine.new(Class.new)
    machine.state :entry, :safe, :loop_a, :loop_b, :done
    analysis = StateMachines::ProbabilisticAnalysis.new(machine)
    analysis.branch from: :entry, to: :safe, probability: 0.5
    analysis.branch from: :entry, to: :loop_a, probability: 0.5
    analysis.branch from: :safe, to: :done, probability: 1.0, cost: 4
    analysis.branch from: :loop_a, to: :loop_b, probability: 1.0
    analysis.branch from: :loop_b, to: :loop_a, probability: 1.0

    probabilities = analysis.absorption_probabilities(to: :done)
    assert_in_delta 0.5, probabilities[:entry]
    assert_in_delta 1.0, probabilities[:safe]
    assert_in_delta 0.0, probabilities[:loop_a]
    assert_in_delta 0.0, probabilities[:loop_b]
    assert_in_delta 1.0, probabilities[:done]

    costs = analysis.expected_costs(to: :done)
    assert_equal Float::INFINITY, costs[:entry]
    assert_in_delta 4.0, costs[:safe]
    assert_equal Float::INFINITY, costs[:loop_a]
    assert_equal Float::INFINITY, costs[:loop_b]
    assert_equal 0.0, costs[:done]
  end

  def test_should_default_cost_to_one_transition
    machine = StateMachines::Machine.new(Class.new)
    machine.state :a, :b
    analysis = StateMachines::ProbabilisticAnalysis.new(machine)
    analysis.branch from: :a, to: :a, probability: 0.5
    analysis.branch from: :a, to: :b, probability: 0.5

    assert_in_delta 2.0, analysis.expected_cost(from: :a, to: :b)
  end

  def test_should_expose_single_state_helpers
    build_bad_loop_model

    assert_in_delta 0.5, @analysis.absorption_probability(from: :start, to: :done)
    assert_equal Float::INFINITY, @analysis.expected_cost(from: :spin_a, to: :done)
  end

  def test_should_raise_when_probabilities_do_not_sum_to_one
    @analysis.branch from: :start, to: :done, probability: 0.4

    error = assert_raises(ArgumentError) { @analysis.validate! }
    assert_match(/:start sum to 0.4/, error.message)
  end

  def test_should_raise_for_probability_out_of_range
    assert_raises(ArgumentError) { @analysis.branch from: :start, to: :done, probability: 0 }
    assert_raises(ArgumentError) { @analysis.branch from: :start, to: :done, probability: -0.1 }
    assert_raises(ArgumentError) { @analysis.branch from: :start, to: :done, probability: 1.5 }
  end

  def test_should_raise_for_negative_cost
    assert_raises(ArgumentError) { @analysis.branch from: :start, to: :done, probability: 1.0, cost: -1 }
  end

  def test_should_raise_for_unknown_branch_states
    @analysis.branch from: :start, to: :nowhere, probability: 1.0

    error = assert_raises(ArgumentError) { @analysis.validate! }
    assert_match(/unknown state/, error.message)
  end

  def test_should_raise_for_unknown_target_state
    build_bad_loop_model

    assert_raises(ArgumentError) { @analysis.absorption_probabilities(to: :nowhere) }
    assert_raises(ArgumentError) { @analysis.expected_costs(to: :nowhere) }
  end
end
