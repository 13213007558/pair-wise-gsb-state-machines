# frozen_string_literal: true

require 'test_helper'

class PetriNetTest < StateMachinesTest
  def test_fires_weighted_arcs_without_reducing_tokens_to_booleans
    net = StateMachines::PetriNet::BoundedPetriNet.new do
      place :waiting, capacity: 3, tokens: 2
      place :workers, capacity: 2, tokens: 2
      place :running, capacity: 2, tokens: 0

      transition :start, input: { waiting: 2, workers: 2 }, output: { running: 2 }
    end

    assert net.fire(:start)
    refute net.enabled?(:start)
    assert_equal({ waiting: 0, workers: 0, running: 2 }, net.marking)
  end

  def test_explicit_zero_initial_tokens_override_place_default
    net = StateMachines::PetriNet::BoundedPetriNet.new(
      initial_marking: { waiting: 0 }
    ) do
      place :waiting, capacity: 2, tokens: 2
    end

    assert_equal({ waiting: 0 }, net.marking)
    assert net.marking.frozen?
  end

  def test_read_only_arc_checks_tokens_without_consuming_them
    net = StateMachines::PetriNet::BoundedPetriNet.new do
      place :work, capacity: 1, tokens: 1
      place :resource, capacity: 1, tokens: 1

      transition :inspect, read: { work: 1, resource: 1 }
      transition :consume, input: { resource: 1 }
    end

    assert net.fire(:inspect)
    assert_equal({ work: 1, resource: 1 }, net.marking)

    assert net.fire(:consume)
    refute net.enabled?(:inspect)
    assert_equal({ work: 1, resource: 0 }, net.marking)
  end

  def test_firing_is_atomic_when_output_capacity_would_be_exceeded
    net = StateMachines::PetriNet::BoundedPetriNet.new do
      place :waiting, capacity: 1, tokens: 1
      place :buffer, capacity: 1, tokens: 1

      transition :move, input: { waiting: 1 }, output: { buffer: 1 }
    end

    refute net.fire(:move)
    assert_equal({ waiting: 1, buffer: 1 }, net.marking)
  end

  def test_two_operations_contend_for_one_shared_resource_and_conserve_tokens
    net = two_operations_net
    analysis = net.analyze_reachability

    assert analysis.complete?
    assert_equal 8, analysis.reachable_markings.size
    assert analysis.deadlocked?
    assert_equal [final_two_operations_marking], analysis.deadlock_markings

    analysis.reachable_markings.each do |marking|
      assert_operator marking[:active_one] + marking[:active_two], :<=, 1
      assert_equal 1, marking[:resource] + marking[:holding]
      assert_equal 3, net.token_count(marking)
    end

    assert net.fire!(:start_one)
    refute net.enabled?(:start_two)
    assert_equal 0, net.marking[:resource]
    assert_equal 1, net.marking[:holding]
    assert_equal 1, net.marking[:active_one]
    assert_equal 0, net.marking[:active_two]

    assert net.fire!(:finish_one)
    assert net.fire!(:start_two)
    assert net.fire!(:finish_two)
    assert_equal final_two_operations_marking, net.marking
    assert_equal 3, net.token_count
  end

  def test_cycle_returns_shared_resource_for_repeated_acquisition
    net = StateMachines::PetriNet::BoundedPetriNet.new do
      place :waiting, capacity: 2, tokens: 2
      place :active, capacity: 1, tokens: 0
      place :resource, capacity: 1, tokens: 1
      place :holding, capacity: 1, tokens: 0

      transition :acquire, input: { waiting: 1, resource: 1 }, output: { active: 1, holding: 1 }
      transition :release, input: { active: 1, holding: 1 }, output: { waiting: 1, resource: 1 }
    end

    analysis = net.analyze_reachability

    assert analysis.complete?
    assert_empty analysis.deadlock_markings
    assert_equal(
      [
        { waiting: 2, active: 0, resource: 1, holding: 0 },
        { waiting: 1, active: 1, resource: 0, holding: 1 }
      ],
      analysis.reachable_markings
    )

    4.times do
      assert net.fire!(:acquire)
      assert_equal({ waiting: 1, active: 1, resource: 0, holding: 1 }, net.marking)
      assert_equal 3, net.token_count

      assert net.fire!(:release)
      assert_equal({ waiting: 2, active: 0, resource: 1, holding: 0 }, net.marking)
      assert_equal 3, net.token_count
    end
  end

  def test_reachability_analysis_reports_incomplete_when_state_limit_is_reached
    net = cycle_net
    analysis = net.analyze_reachability(state_limit: 1)

    assert analysis.incomplete?
    refute analysis.deadlocked?
    assert_equal 1, analysis.reachable_markings.size
    assert_empty analysis.deadlock_markings
  end

  def test_reaching_exact_state_limit_is_also_reported_as_incomplete
    analysis = cycle_net.analyze_reachability(state_limit: 2)

    assert analysis.incomplete?
    assert_equal 2, analysis.states_visited
  end

  def test_unknown_and_disabled_transitions_use_distinct_failure_modes
    net = two_operations_net

    refute net.fire(:missing)
    assert_raises(StateMachines::PetriNet::UnknownTransition) do
      net.fire!(:missing)
    end

    assert net.fire!(:start_one)
    assert_raises(StateMachines::PetriNet::TransitionNotEnabled) do
      net.fire!(:start_two)
    end
  end

  private

  def cycle_net
    StateMachines::PetriNet::BoundedPetriNet.new do
      place :waiting, capacity: 2, tokens: 2
      place :active, capacity: 1, tokens: 0
      place :resource, capacity: 1, tokens: 1
      place :holding, capacity: 1, tokens: 0

      transition :acquire, input: { waiting: 1, resource: 1 }, output: { active: 1, holding: 1 }
      transition :release, input: { active: 1, holding: 1 }, output: { waiting: 1, resource: 1 }
    end
  end

  def two_operations_net
    StateMachines::PetriNet::BoundedPetriNet.new do
      place :ready_one, capacity: 1, tokens: 1
      place :ready_two, capacity: 1, tokens: 1
      place :active_one, capacity: 1, tokens: 0
      place :active_two, capacity: 1, tokens: 0
      place :done_one, capacity: 1, tokens: 0
      place :done_two, capacity: 1, tokens: 0
      place :resource, capacity: 1, tokens: 1
      place :holding, capacity: 1, tokens: 0

      transition :start_one, input: { ready_one: 1, resource: 1 }, output: { active_one: 1, holding: 1 }
      transition :finish_one, input: { active_one: 1, holding: 1 }, output: { done_one: 1, resource: 1 }
      transition :start_two, input: { ready_two: 1, resource: 1 }, output: { active_two: 1, holding: 1 }
      transition :finish_two, input: { active_two: 1, holding: 1 }, output: { done_two: 1, resource: 1 }
    end
  end

  def final_two_operations_marking
    {
      ready_one: 0,
      ready_two: 0,
      active_one: 0,
      active_two: 0,
      done_one: 1,
      done_two: 1,
      resource: 1,
      holding: 0
    }
  end
end
