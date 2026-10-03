# frozen_string_literal: true

require 'test_helper'

class SynchronizingSequenceWithSingleStateTest < StateMachinesTest
  def setup
    @klass = Class.new
    @machine = StateMachines::Machine.new(@klass, initial: :parked)
    @sequence = @machine.synchronizing_sequence
  end

  def test_should_synchronize
    assert_predicate @sequence, :synchronizes?
  end

  def test_should_not_require_events
    assert_equal [], @sequence.events
    assert_equal [], @sequence.steps
  end

  def test_should_know_final_state
    assert_equal :parked, @sequence.final_state
  end
end
