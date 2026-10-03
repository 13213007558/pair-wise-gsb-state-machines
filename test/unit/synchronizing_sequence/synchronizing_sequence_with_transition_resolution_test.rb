# frozen_string_literal: true

require 'test_helper'

class SynchronizingSequenceWithTransitionResolutionTest < StateMachinesTest
  def setup
    @klass = Class.new
    @machine = StateMachines::Machine.new(@klass, initial: :parked)
    @machine.state :idling, :stalled
  end

  def test_should_treat_undefined_event_states_as_unchanged
    @machine.event :park do
      transition idling: :parked, stalled: :parked
    end

    sequence = @machine.synchronizing_sequence

    assert_equal %i[park], sequence.events
    assert_equal :parked, sequence.final_state
  end

  def test_should_treat_loopback_transitions_as_unchanged
    @machine.event :park do
      transition idling: :parked
      transition parked: same
    end
    @machine.event :stall do
      transition stalled: :parked
    end

    sequence = @machine.synchronizing_sequence

    assert_predicate sequence, :synchronizes?
    assert_equal :parked, sequence.final_state
  end

  def test_should_resolve_ambiguous_targets_like_the_runtime
    @machine.event :shift do
      transition parked: %i[idling stalled]
    end
    @machine.event :park do
      transition idling: :parked, stalled: :parked
    end

    sequence = @machine.synchronizing_sequence(from_states: %i[parked idling])

    assert_equal %i[shift], sequence.events
    assert_equal :idling, sequence.final_state
  end

  def test_should_use_first_matching_branch
    @machine.event :reset do
      transition all => :parked
      transition parked: :stalled
    end

    sequence = @machine.synchronizing_sequence

    assert_equal %i[reset], sequence.events
    assert_equal :parked, sequence.final_state
  end
end
