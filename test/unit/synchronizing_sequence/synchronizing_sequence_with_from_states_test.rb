# frozen_string_literal: true

require 'test_helper'

class SynchronizingSequenceWithFromStatesTest < StateMachinesTest
  def setup
    @klass = Class.new
    @machine = StateMachines::Machine.new(@klass, initial: :disconnected)
    @machine.state :booting, :ready
    @machine.event :boot do
      transition disconnected: :booting
    end
    @machine.event :complete do
      transition booting: :ready
    end
  end

  def test_should_only_synchronize_given_states
    sequence = @machine.synchronizing_sequence(from_states: %i[disconnected ready])

    assert_predicate sequence, :synchronizes?
    assert_equal %i[disconnected ready], sequence.initial_states
    assert_equal %i[boot complete], sequence.events
    assert_equal :ready, sequence.final_state
  end

  def test_should_track_remaining_states_from_given_states
    sequence = @machine.synchronizing_sequence(from_states: %i[disconnected ready])

    assert_equal [
      StateMachines::SynchronizingSequence::Step.new(:boot, %i[booting ready]),
      StateMachines::SynchronizingSequence::Step.new(:complete, %i[ready])
    ], sequence.steps
  end

  def test_should_accept_string_state_names
    sequence = @machine.synchronizing_sequence(from_states: %w[disconnected booting])

    assert_equal %i[disconnected booting], sequence.initial_states
  end

  def test_should_synchronize_trivially_from_single_state
    sequence = @machine.synchronizing_sequence(from_states: :ready)

    assert_predicate sequence, :synchronizes?
    assert_equal [], sequence.events
    assert_equal [], sequence.steps
    assert_equal :ready, sequence.final_state
  end

  def test_should_raise_for_unknown_state
    assert_raises(IndexError) { @machine.synchronizing_sequence(from_states: [:invalid]) }
  end

  def test_should_raise_for_no_states
    assert_raises(ArgumentError) { @machine.synchronizing_sequence(from_states: []) }
  end
end
