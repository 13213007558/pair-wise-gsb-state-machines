# frozen_string_literal: true

require 'test_helper'

class BoundedPetriNetTest < StateMachinesTest
  def setup
    @resource_net = StateMachines::BoundedPetriNet::Net.define(
      initial_marking: { waiting: 2, tool_available: 1 }
    ) do
      place :waiting, capacity: 2
      place :processing_a, capacity: 1
      place :processing_b, capacity: 1
      place :tool_available, capacity: 1
      place :tool_held, capacity: 1

      transition :start_a,
                 inputs: { waiting: 1, tool_available: 1 },
                 outputs: { processing_a: 1, tool_held: 1 }
      transition :finish_a,
                 inputs: { processing_a: 1, tool_held: 1 },
                 outputs: { waiting: 1, tool_available: 1 }
      transition :start_b,
                 inputs: { waiting: 1, tool_available: 1 },
                 outputs: { processing_b: 1, tool_held: 1 }
      transition :finish_b,
                 inputs: { processing_b: 1, tool_held: 1 },
                 outputs: { waiting: 1, tool_available: 1 }
    end
  end

  def test_keeps_multiple_tokens_as_integer_counts
    assert_equal 2, @resource_net.initial_marking[:waiting]
    assert_equal %i[start_a start_b], @resource_net.enabled_transitions

    after_start = @resource_net.fire!(:start_a)

    assert_equal 1, after_start[:waiting]
    assert_equal 1, after_start[:processing_a]
    assert_equal 1, after_start[:tool_held]
    assert_equal 0, after_start[:tool_available]
    assert_equal 0, after_start[:processing_b]
  end

  def test_only_one_processing_step_can_acquire_shared_resource
    after_start = @resource_net.fire!(:start_a)

    assert_equal [:finish_a], @resource_net.enabled_transitions(after_start)
    assert_nil @resource_net.fire(:start_b, after_start)
    assert_raises(StateMachines::BoundedPetriNet::TransitionNotEnabled) do
      @resource_net.fire!(:start_b, after_start)
    end
  end

  def test_finishing_returns_resource_and_preserves_tokens_around_cycle
    after_start = @resource_net.fire!(:start_a)
    after_finish = @resource_net.fire!(:finish_a, after_start)
    after_restart_with_b = @resource_net.fire!(:start_b, after_finish)
    after_cycle = @resource_net.fire!(:finish_b, after_restart_with_b)

    assert_equal @resource_net.initial_marking, after_cycle
    [
      @resource_net.initial_marking,
      after_start,
      after_finish,
      after_restart_with_b,
      after_cycle
    ].each do |marking|
      assert_equal 3, marking.total_tokens
    end
  end

  def test_analyzes_complete_reachable_markings_without_deadlocks
    result = @resource_net.analyze

    assert_predicate result, :complete?
    refute_predicate result, :incomplete?
    assert_empty result.deadlock_markings
    assert_equal 3, result.reachable_markings.size
    assert(result.reachable_markings.all? { |marking| marking.total_tokens == 3 })
  end

  def test_read_arcs_require_tokens_without_consuming_them
    net = StateMachines::BoundedPetriNet::Net.define(
      initial_marking: { waiting: 1, power: 2, processed: 0 }
    ) do
      place :waiting, capacity: 1
      place :power, capacity: 2
      place :processed, capacity: 1
      transition :run,
                 inputs: { waiting: 1 },
                 outputs: { processed: 1 },
                 read_arcs: { power: 2 }
    end

    assert_includes net.enabled_transitions, :run
    marking = net.fire!(:run)

    assert_equal 0, marking[:waiting]
    assert_equal 1, marking[:processed]
    assert_equal 2, marking[:power]
    low_power = StateMachines::BoundedPetriNet::Marking.new(waiting: 1, power: 1, processed: 0)
    refute_includes net.enabled_transitions(low_power), :run
  end

  def test_uses_weighted_arcs_for_multi_token_steps
    net = StateMachines::BoundedPetriNet::Net.define(initial_marking: { waiting: 1 }) do
      place :waiting, capacity: 2
      place :batch, capacity: 1
      transition :batch, inputs: { waiting: 2 }, outputs: { batch: 1 }
    end

    refute_includes net.enabled_transitions, :batch
    assert_equal({ batch: 1 }, net.fire!(:batch, 'waiting' => 2).to_h)
  end

  def test_fire_is_atomic_when_output_capacity_is_exceeded
    net = StateMachines::BoundedPetriNet::Net.define(
      initial_marking: { waiting: 1, processed: 1 }
    ) do
      place :waiting, capacity: 1
      place :processed, capacity: 1
      transition :process, inputs: { waiting: 1 }, outputs: { processed: 1 }
    end
    marking = net.initial_marking

    assert_nil net.fire(:process, marking)
    assert_equal 1, marking[:waiting]
    assert_equal 1, marking[:processed]
  end

  def test_reports_incomplete_analysis_when_state_limit_is_reached
    net = StateMachines::BoundedPetriNet::Net.define(initial_marking: { empty: 1, full: 0 }) do
      place :empty, capacity: 1
      place :full, capacity: 1
      transition :produce, inputs: { empty: 1 }, outputs: { full: 1 }
      transition :consume, inputs: { full: 1 }, outputs: { empty: 1 }
    end

    result = net.analyze(max_states: 1)

    refute_predicate result, :complete?
    assert_predicate result, :incomplete?
    assert_equal 1, result.reachable_markings.size
    assert_empty result.deadlock_markings
  end

  def test_finds_deadlock_markings_in_a_complete_analysis
    net = StateMachines::BoundedPetriNet::Net.define(initial_marking: { waiting: 1, done: 0 }) do
      place :waiting, capacity: 1
      place :done, capacity: 1
      transition :finish, inputs: { waiting: 1 }, outputs: { done: 1 }
    end

    result = net.analyze

    assert_predicate result, :complete?
    assert_equal [{ done: 1 }], result.deadlock_markings.map(&:to_h)
  end

  def test_rejects_initial_marking_that_exceeds_place_capacity
    error = assert_raises(StateMachines::BoundedPetriNet::DefinitionError) do
      StateMachines::BoundedPetriNet::Net.define(initial_marking: { waiting: 2 }) do
        place :waiting, capacity: 1
      end
    end

    assert_match(/exceeds capacity/, error.message)
  end
end
