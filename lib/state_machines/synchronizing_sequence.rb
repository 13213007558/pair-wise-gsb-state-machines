# frozen_string_literal: true

require_relative 'options_validator'

module StateMachines
  # A synchronizing sequence is a single sequence of events that drives a
  # machine into one known state, no matter which of the possible states it
  # currently occupies.  This is useful when the current state of an object
  # has been lost (for example, after a device reconnects) but events can
  # still be sent to it: firing the sequence is guaranteed to leave the
  # object in a single known state.
  #
  # The sequence is computed with a breadth-first search over sets of
  # possible states, so the result is guaranteed to be the shortest
  # synchronizing sequence for the machine.  If no such sequence exists, a
  # pair of states that can never be merged into one is reported instead.
  #
  # Only finite machines with deterministic, guard-free transitions are
  # supported: events whose transitions define :if/:unless conditions depend
  # on the object at runtime and will raise an ArgumentError.
  #
  # == Examples
  #
  #   sequence = machine.synchronizing_sequence
  #   if sequence.synchronizes?
  #     sequence.events       # => [:reset, :ignite]
  #     sequence.final_state  # => :idling
  #     sequence.steps        # => [#<struct StateMachines::SynchronizingSequence::Step event=:reset, remaining_states=[:parked, :idling]>, ...]
  #   else
  #     sequence.unmergeable_pair  # => [:first_gear, :second_gear]
  #   end
  class SynchronizingSequence
    # A single step of a synchronizing sequence, tracking the event to fire
    # and the states the machine may still occupy afterwards
    Step = Struct.new(:event, :remaining_states)

    # Branch internals that make a transition depend on the object at runtime
    GUARD_CONDITIONS = %i[
      @if_condition @unless_condition
      @if_state_condition @unless_state_condition
      @if_all_states_condition @unless_all_states_condition
      @if_any_state_condition @unless_any_state_condition
    ].freeze

    # The machine this sequence was computed for
    attr_reader :machine

    # The states the machine may occupy before any event is fired
    attr_reader :initial_states

    # The steps of the sequence, or nil if the machine cannot be synchronized
    attr_reader :steps

    # The single known state reached after firing the sequence, or nil if the
    # machine cannot be synchronized
    attr_reader :final_state

    # A pair of states that can never be merged into a single state, or nil
    # if the machine can be synchronized
    attr_reader :unmergeable_pair

    # Creates a new synchronizing sequence for the given machine.
    #
    # Configuration options:
    # * <tt>:from_states</tt> - The states the machine may currently occupy.
    #   Defaults to all known states.
    # * <tt>:except_events</tt> - Events that cannot be fired and must be
    #   excluded from the sequence.
    def initialize(machine, options = {})
      options = { from_states: nil, except_events: [] }.merge(options)
      StateMachines::OptionsValidator.assert_valid_keys!(options, :from_states, :except_events)

      @machine = machine
      @state_names = machine.states.map(&:name)
      @state_index = @state_names.each_with_index.to_h
      @initial_states = normalize_states(options[:from_states])
      @event_names = normalize_events(options[:except_events])
      @transitions = build_transitions

      search
    end

    # Whether a sequence of events exists that merges all of the initial
    # states into a single known state
    def synchronizes?
      !@steps.nil?
    end

    # The ordered events to fire, or nil if the machine cannot be synchronized
    def events
      @steps&.map(&:event)
    end

    private

    # Normalizes the set of states the machine may start in, keeping machine
    # state order
    def normalize_states(from_states)
      names = from_states.nil? ? @state_names : Array(from_states).map { |name| machine.states.fetch(name).name }
      raise ArgumentError, 'must specify at least one from state' if names.empty?

      @state_names & names
    end

    # Normalizes the set of events that may be fired, keeping machine event
    # order
    def normalize_events(except_events)
      excluded = Array(except_events).map { |name| machine.events.fetch(name).name }
      machine.events.map(&:name) - excluded
    end

    # Builds the deterministic transition function for each usable event as
    # {event => {state => state}}
    def build_transitions
      @event_names.to_h do |event_name|
        event = machine.events.fetch(event_name)
        assert_unguarded!(event)
        [event_name, @state_names.to_h { |state| [state, target_for(event, state) || state] }]
      end
    end

    # Verifies that none of the event's branches depend on the object at
    # runtime
    def assert_unguarded!(event)
      guarded = event.branches.any? do |branch|
        GUARD_CONDITIONS.any? { |ivar| branch.instance_variable_get(ivar) }
      end
      raise ArgumentError, "cannot compute a synchronizing sequence for event #{event.name.inspect}: transitions with :if/:unless conditions depend on the object at runtime" if guarded
    end

    # Finds the state the given event transitions to from the given state,
    # mirroring Event#transition_for: the first matching branch wins, a
    # loopback keeps the current state, and an ambiguous target resolves to
    # the first matching state (preferring the current one).  Returns nil if
    # the event cannot be fired from the state.
    def target_for(event, state)
      event.branches.each do |branch|
        branch.state_requirements.each do |requirement|
          next unless requirement[:from].matches?(state)

          to = requirement[:to]
          return state if to.is_a?(StateMachines::LoopbackMatcher)

          target = to.filter([state] | @state_names).first
          return target if target
        end
      end
      nil
    end

    # Computes the states the machine may occupy after firing the given event
    # from any of the given states
    def successor_states(states, event)
      map = @transitions[event]
      states.map { |state| map[state] }.uniq.sort_by { |state| @state_index[state] }
    end

    # Searches sets of possible states breadth-first for a sequence that
    # merges all of the initial states into one
    def search
      if @initial_states.length == 1
        @final_state = @initial_states.first
        @steps = []
        return
      end

      parents = { @initial_states => nil }
      queue = [@initial_states]
      goal = nil

      until queue.empty? || goal
        current = queue.shift
        @event_names.each do |event|
          successor = successor_states(current, event)
          next if parents.key?(successor)

          parents[successor] = [current, event]
          if successor.length == 1
            goal = successor
            break
          end
          queue << successor
        end
      end

      if goal
        @final_state = goal.first
        @steps = build_steps(goal, parents)
      else
        @unmergeable_pair = find_unmergeable_pair
      end
    end

    # Reconstructs the steps that lead from the initial states to the goal,
    # tracking the states that remain possible after each event
    def build_steps(goal, parents)
      word = []
      node = goal
      while (parent = parents[node])
        word.unshift(parent[1])
        node = parent[0]
      end

      states = @initial_states
      word.map do |event|
        states = successor_states(states, event)
        Step.new(event, states)
      end
    end

    # Finds a pair of initial states that no sequence of events can merge
    # into a single state, by walking the pair graph backwards from the
    # pairs that are already merged
    def find_unmergeable_pair
      predecessors = Hash.new { |hash, key| hash[key] = [] }
      @state_names.combination(2) do |pair|
        @event_names.each do |event|
          image = successor_states(pair, event)
          predecessors[image] << pair unless image == pair
        end
      end

      mergeable = {}
      queue = @state_names.map { |state| [state] }
      queue.each { |singleton| mergeable[singleton] = true }
      until queue.empty?
        predecessors[queue.shift].each do |pair|
          next if mergeable[pair]

          mergeable[pair] = true
          queue << pair
        end
      end

      @initial_states.combination(2) do |pair|
        return pair unless mergeable[pair]
      end
      nil
    end
  end
end
