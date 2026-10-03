# frozen_string_literal: true

require 'test_helper'

class SynchronizingSequenceWithGuardsTest < StateMachinesTest
  def setup
    @klass = Class.new do
      attr_accessor :ready
    end
    @machine = StateMachines::Machine.new(@klass, initial: :parked)
    @machine.state :idling
  end

  def test_should_raise_for_if_condition
    @machine.event :ignite do
      transition parked: :idling, if: :ready
    end

    exception = assert_raises(ArgumentError) { @machine.synchronizing_sequence }
    assert_match(%r{:if/:unless conditions}, exception.message)
  end

  def test_should_raise_for_unless_condition
    @machine.event :ignite do
      transition parked: :idling, unless: :ready
    end

    exception = assert_raises(ArgumentError) { @machine.synchronizing_sequence }
    assert_match(%r{:if/:unless conditions}, exception.message)
  end

  def test_should_ignore_guards_on_excluded_events
    @machine.event :ignite do
      transition parked: :idling, if: :ready
    end
    @machine.event :park do
      transition idling: :parked
    end

    sequence = @machine.synchronizing_sequence(except_events: [:ignite])

    assert_predicate sequence, :synchronizes?
    assert_equal %i[park], sequence.events
  end
end
