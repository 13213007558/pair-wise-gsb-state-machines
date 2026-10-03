# frozen_string_literal: true

require 'test_helper'

class MachineSynchronizingSequenceTest < StateMachinesTest
  def setup
    @klass = Class.new
    @machine = StateMachines::Machine.new(@klass, initial: :parked)
    @machine.event :shift_up do
      transition parked: :idling
      transition idling: :driving
    end
    @machine.event :reset do
      transition driving: :parked
    end
  end

  # Fires the given events on a fresh object for each of the given states and
  # returns the resulting states.  This simulates the sequence independently
  # of the implementation under test.
  def simulate(machine, from_states, events)
    from_states.map do |state|
      object = machine.owner_class.new
      object.state = state.to_s
      events.each { |event| machine.events[event].fire(object) }
      machine.states.match!(object).name
    end
  end

  # All words over the given events, up to the given length, that synchronize
  # the given states into a single state
  def synchronizing_words(machine, from_states, events, max_length)
    (0..max_length).flat_map do |length|
      events.repeated_permutation(length).select do |word|
        simulate(machine, from_states, word).uniq.length == 1
      end
    end
  end

  def test_should_find_shortest_synchronizing_sequence
    sequence = @machine.synchronizing_sequence

    assert sequence.synchronized?
    # Firing the shortest path for each state individually would concatenate
    # to [:shift_up, :shift_up, :shift_up]; searching sets of states finds
    # the actual shortest sequence
    assert_equal %i[shift_up shift_up], sequence.events
    assert_equal :driving, sequence.state
  end

  def test_should_track_remaining_states_for_each_step
    sequence = @machine.synchronizing_sequence

    assert_equal %i[parked idling driving], sequence.from_states
    assert_equal 2, sequence.steps.length
    assert_equal :shift_up, sequence.steps[0].event
    assert_equal %i[idling driving], sequence.steps[0].states
    assert_equal :shift_up, sequence.steps[1].event
    assert_equal %i[driving], sequence.steps[1].states
    assert_equal %i[driving], sequence.states
  end

  def test_should_synchronize_from_subset_of_states
    sequence = @machine.synchronizing_sequence(from: %i[idling driving])

    assert sequence.synchronized?
    assert_equal %i[idling driving], sequence.from_states
    assert_equal %i[shift_up], sequence.events
    assert_equal :driving, sequence.state
  end

  def test_should_accept_a_single_from_state
    sequence = @machine.synchronizing_sequence(from: :parked)

    assert sequence.synchronized?
    assert_empty sequence.events
    assert_equal :parked, sequence.state
  end

  def test_should_exclude_events_that_cannot_be_sent
    sequence = @machine.synchronizing_sequence(except: :shift_up)

    refute sequence.synchronized?
    assert_empty sequence.events
    assert_nil sequence.state
    assert_equal %i[parked idling], sequence.unmergeable_pair
  end

  def test_should_accept_a_single_excluded_event
    sequence = @machine.synchronizing_sequence(except: :reset)

    assert sequence.synchronized?
    assert_equal %i[shift_up shift_up], sequence.events
  end

  def test_should_report_unmergeable_pair_when_not_synchronizable
    machine = StateMachines::Machine.new(Class.new, initial: :a)
    machine.event :flip do
      transition a: :b
      transition b: :a
      transition c: :d
      transition d: :c
    end

    sequence = machine.synchronizing_sequence

    refute sequence.synchronized?
    assert_empty sequence.events
    assert_nil sequence.state
    assert_equal %i[a b], sequence.unmergeable_pair
  end

  def test_should_raise_on_guarded_events
    @machine.event :park do
      transition idling: :parked, if: :allowed?
    end

    exception = assert_raises(ArgumentError) { @machine.synchronizing_sequence }
    assert_match(/guarded/, exception.message)
  end

  def test_should_allow_guarded_events_to_be_excluded
    @machine.event :park do
      transition idling: :parked, if: :allowed?
    end

    sequence = @machine.synchronizing_sequence(except: :park)

    assert sequence.synchronized?
    assert_equal %i[shift_up shift_up], sequence.events
  end

  def test_should_raise_on_invalid_from_state
    assert_raises(IndexError) { @machine.synchronizing_sequence(from: :invalid) }
  end

  def test_should_raise_on_invalid_except_event
    assert_raises(IndexError) { @machine.synchronizing_sequence(except: :invalid) }
  end

  def test_should_raise_on_invalid_option
    assert_raises(ArgumentError) { @machine.synchronizing_sequence(invalid: true) }
  end

  def test_should_support_any_from_matcher
    machine = StateMachines::Machine.new(Class.new, initial: :a)
    machine.state :b, :c
    machine.event(:hom) { transition any => :a }

    sequence = machine.synchronizing_sequence

    assert sequence.synchronized?
    assert_equal %i[hom], sequence.events
    assert_equal :a, sequence.state
  end

  def test_should_support_except_from_matcher
    machine = StateMachines::Machine.new(Class.new, initial: :a)
    machine.state :b, :c
    machine.event(:hom) { transition except_from: :a, to: :a }

    sequence = machine.synchronizing_sequence

    assert sequence.synchronized?
    assert_equal %i[hom], sequence.events
    assert_equal :a, sequence.state
  end

  def test_should_support_loopback_transitions
    machine = StateMachines::Machine.new(Class.new, initial: :a)
    machine.state :b
    machine.event(:ping) { transition a: same }
    machine.event(:hom) { transition any => :a }

    sequence = machine.synchronizing_sequence

    assert sequence.synchronized?
    assert_equal %i[hom], sequence.events
    assert_equal :a, sequence.state
  end

  def test_should_verify_shortest_sequence_against_brute_force
    machine = StateMachines::Machine.new(Class.new, initial: :s0)
    machine.event :rot do
      transition s0: :s1
      transition s1: :s2
      transition s2: :s0
    end
    machine.event :fix do
      transition s1: :s0
    end

    sequence = machine.synchronizing_sequence

    assert sequence.synchronized?
    assert_equal 3, sequence.length

    # No shorter word synchronizes the machine, and the returned sequence does
    events = %i[rot fix]
    assert_empty synchronizing_words(machine, %i[s0 s1 s2], events, sequence.length - 1)
    assert_equal [sequence.state], simulate(machine, %i[s0 s1 s2], sequence.events).uniq
  end

  def test_should_verify_sequence_against_actual_event_firing
    sequence = @machine.synchronizing_sequence

    assert_equal [sequence.state], simulate(@machine, sequence.from_states, sequence.events).uniq
  end

  def test_should_verify_each_step_against_actual_event_firing
    sequence = @machine.synchronizing_sequence
    possible = sequence.from_states

    sequence.steps.each do |step|
      assert_equal step.states.sort, simulate(@machine, possible, [step.event]).uniq.sort
      possible = step.states
    end
  end
end
