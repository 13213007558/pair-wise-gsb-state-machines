# frozen_string_literal: true

require 'test_helper'

class SynchronizingSequenceTest < StateMachinesTest
  def setup
    @klass = Class.new
    @machine = StateMachines::Machine.new(@klass, initial: :s0)
    @machine.state :s1, :s2
    @machine.event :cycle do
      transition s0: :s1, s1: :s2, s2: :s0
    end
    @machine.event :merge do
      transition s2: :s0
    end
    @sequence = @machine.synchronizing_sequence
  end

  def test_should_synchronize
    assert_predicate @sequence, :synchronizes?
  end

  def test_should_find_shortest_event_sequence
    assert_equal %i[merge cycle cycle merge], @sequence.events
  end

  def test_should_track_initial_states
    assert_equal %i[s0 s1 s2], @sequence.initial_states
  end

  def test_should_track_remaining_states_for_each_step
    assert_equal [
      StateMachines::SynchronizingSequence::Step.new(:merge, %i[s0 s1]),
      StateMachines::SynchronizingSequence::Step.new(:cycle, %i[s1 s2]),
      StateMachines::SynchronizingSequence::Step.new(:cycle, %i[s0 s2]),
      StateMachines::SynchronizingSequence::Step.new(:merge, %i[s0])
    ], @sequence.steps
  end

  def test_should_reach_single_known_state
    assert_equal :s0, @sequence.final_state
  end

  def test_should_not_have_unmergeable_pair
    assert_nil @sequence.unmergeable_pair
  end

  def test_should_actually_synchronize_machine
    assert_equal ['s0'], final_states_after(@sequence.events)
  end

  def test_should_not_find_shorter_sequence_by_brute_force
    shorter = (0...@sequence.events.length).any? do |length|
      %i[cycle merge].repeated_permutation(length).any? do |word|
        final_states_after(word).length == 1
      end
    end
    refute shorter, 'expected no synchronizing sequence shorter than the one found'
  end

  private

  def final_states_after(word)
    %i[s0 s1 s2].map do |start|
      object = @klass.new
      object.state = start.to_s
      word.each { |event| object.send(event) }
      object.state
    end.uniq
  end
end
