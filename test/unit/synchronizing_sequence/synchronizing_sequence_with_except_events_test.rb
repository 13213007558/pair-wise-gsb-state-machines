# frozen_string_literal: true

require 'test_helper'

class SynchronizingSequenceWithExceptEventsTest < StateMachinesTest
  def setup
    @klass = Class.new
    @machine = StateMachines::Machine.new(@klass, initial: :on)
    @machine.state :off
    @machine.event :reset do
      transition off: :on
    end
    @machine.event :ping
  end

  def test_should_ignore_excluded_events
    sequence = @machine.synchronizing_sequence(except_events: [:ping])

    assert_predicate sequence, :synchronizes?
    assert_equal %i[reset], sequence.events
  end

  def test_should_fail_when_required_event_is_excluded
    sequence = @machine.synchronizing_sequence(except_events: [:reset])

    refute_predicate sequence, :synchronizes?
    assert_equal %i[on off], sequence.unmergeable_pair
  end

  def test_should_accept_string_event_names
    sequence = @machine.synchronizing_sequence(except_events: ['ping'])

    assert_equal %i[reset], sequence.events
  end

  def test_should_raise_for_unknown_event
    assert_raises(IndexError) { @machine.synchronizing_sequence(except_events: [:invalid]) }
  end
end
