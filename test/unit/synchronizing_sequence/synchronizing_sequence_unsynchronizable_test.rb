# frozen_string_literal: true

require 'test_helper'

class SynchronizingSequenceUnsynchronizableTest < StateMachinesTest
  def setup
    @klass = Class.new
    @machine = StateMachines::Machine.new(@klass, initial: :red)
    @machine.state :blue, :hub
    @machine.event :swap do
      transition red: :blue, blue: :red
    end
    @sequence = @machine.synchronizing_sequence
  end

  def test_should_not_synchronize
    refute_predicate @sequence, :synchronizes?
  end

  def test_should_not_have_events
    assert_nil @sequence.events
  end

  def test_should_not_have_steps
    assert_nil @sequence.steps
  end

  def test_should_not_have_final_state
    assert_nil @sequence.final_state
  end

  def test_should_report_unmergeable_pair
    assert_equal %i[red blue], @sequence.unmergeable_pair
  end

  def test_should_report_unmergeable_pair_within_from_states
    sequence = @machine.synchronizing_sequence(from_states: %i[blue hub])

    refute_predicate sequence, :synchronizes?
    assert_equal %i[blue hub], sequence.unmergeable_pair
  end
end
