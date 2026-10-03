# frozen_string_literal: true

require_relative 'options_validator'

module StateMachines
  # Represents the result of searching for the shortest synchronizing sequence
  # of a machine.
  #
  # A synchronizing sequence is a single sequence of events that drives a
  # machine into one known state, regardless of which of the possible states
  # the machine actually started in.  This is useful when the current state of
  # an object has been lost (for example, after a device reconnects) but
  # events can still be sent to it:  firing the sequence guarantees the object
  # ends up in a single, known state.
  #
  # The sequence is computed by searching the space of *sets* of possible
  # states (rather than concatenating paths found for each state individually),
  # so the result is guaranteed to be the shortest possible sequence.  Firing
  # an event that has no transition from a particular state is treated as
  # leaving that state unchanged, matching the runtime behavior of the machine.
  #
  # Only machines whose transitions are unguarded can be synchronized
  # statically; an ArgumentError is raised if any of the usable events has
  # guarded transitions.  Events that cannot be fired by the caller (including
  # guarded ones) can be left out with the <tt>:except</tt> option.
  #
  # == Examples
  #
  #   sequence = machine.synchronizing_sequence
  #   sequence.synchronized?      # => true
  #   sequence.events             # => [:shift_up, :shift_up]
  #   sequence.state              # => :driving
  #   sequence.steps.map(&:states) # => [[:idling, :driving], [:driving]]
  #
  #   # Only synchronize from a subset of possible states
  #   machine.synchronizing_sequence(from: [:idling, :driving])
  #
  #   # Exclude events that cannot be fired
  #   machine.synchronizing_sequence(except: :repair)
  #
  #   # Machines that cannot be synchronized
  #   sequence = machine.synchronizing_sequence
  #   sequence.synchronized?      # => false
  #   sequence.unmergeable_pair   # => [:a, :b]
  class SynchronizingSequence
    # A single step in a synchronizing sequence:  the event to fire and the
    # states the machine may still be in after the event has been fired.
    class Step
      # The event to fire for this step
      attr_reader :event

      # The possible states remaining after the event has been fired
      attr_reader :states

      def initialize(event, states) # :nodoc:
        @event = event
        @states = states
      end

      def ==(other)
        other.is_a?(Step) && other.event == event && other.states == states
      end

      def inspect
        "#<#{self.class.name} #{event.inspect} -> #{states.inspect}>"
      end
    end

    # The machine this sequence was generated for
    attr_reader :machine

    # The states the machine was known to be in before firing the sequence
    attr_reader :from_states

    # The events that were excluded from the search
    attr_reader :excluded_events

    # The steps of the sequence, each tracking the event fired and the
    # possible states remaining afterwards.  Empty if no events are needed or
    # no synchronizing sequence exists.
    attr_reader :steps

    # A pair of states that can never be merged into a single state by any
    # sequence of events.  Only set when the machine cannot be synchronized.
    attr_reader :unmergeable_pair

    # Creates and computes the synchronizing sequence for the given machine.
    #
    # Configuration options:
    # * <tt>:from</tt> - One or more states the machine may currently be in.
    #   Defaults to all states of the machine.
    # * <tt>:except</tt> - One or more events that cannot be fired and must be
    #   excluded from the sequence.
    def initialize(machine, options = {})
      options = { from: nil, except: [] }.merge(options)
      StateMachines::OptionsValidator.assert_valid_keys!(options, :from, :except)

      @machine = machine
      @from_states = resolve_states(options[:from])
      @excluded_events = Array(options[:except]).map { |name| machine.events.fetch(name).name }
      @steps = []
      @synchronized = from_states.length <= 1

      search unless @synchronized
    end

    # The ordered list of events to fire
    def events
      steps.map(&:event)
    end

    # The states the machine may be in after the full sequence has been fired
    def states
      steps.empty? ? from_states : steps.last.states
    end

    # The single state the machine is guaranteed to end up in, or nil if no
    # synchronizing sequence exists
    def state
      states.first if synchronized?
    end

    # Whether a synchronizing sequence was found
    def synchronized?
      @synchronized
    end

    # The number of events in the sequence
    def length
      steps.length
    end

    # Whether the sequence contains no events
    def empty?
      steps.empty?
    end

    private

    # The names of all states, in definition order
    def state_names
      @state_names ||= machine.states.map(&:name)
    end

    # The names of all events that may be fired, in definition order
    def usable_events
      machine.events.map(&:name) - excluded_events
    end

    # Resolves the :from option into a canonical list of state names
    def resolve_states(from)
      return state_names if from.nil?

      canonical(Array(from).map { |name| machine.states.fetch(name).name })
    end

    # Orders a set of state names by definition order and removes duplicates
    def canonical(states)
      states.uniq.sort_by { |state| state_names.index(state) }
    end

    # Searches the space of possible state sets for the shortest sequence of
    # events that collapses the initial set into a single state
    def search
      transitions = usable_events.to_h { |name| [name, transition_map_for(name)] }

      parents = { from_states => nil }
      queue = [from_states]
      goal = nil

      until queue.empty?
        current = queue.shift
        if current.length == 1
          goal = current
          break
        end

        transitions.each do |event_name, map|
          successor = canonical(current.map { |state| map.fetch(state, state) })
          next if parents.key?(successor)

          parents[successor] = [current, event_name]
          queue << successor
        end
      end

      if goal
        @steps = build_steps(parents, goal)
        @synchronized = true
      else
        @unmergeable_pair = find_unmergeable_pair(transitions)
      end
    end

    # Rebuilds the steps that lead from the initial set of states to the goal
    def build_steps(parents, goal)
      steps = []
      node = goal
      while (entry = parents[node])
        parent, event_name = entry
        steps.unshift(Step.new(event_name, node))
        node = parent
      end
      steps
    end

    # Builds the static transition map (from state name to state name) for the
    # given event, mirroring the runtime behavior of picking the first
    # matching branch
    def transition_map_for(event_name)
      event = machine.events[event_name]
      map = {}

      event.branches.each do |branch|
        if branch.guarded?
          raise ArgumentError,
                "Cannot synchronize event #{event_name.inspect} because its transitions are guarded; " \
                'exclude it with the :except option'
        end

        branch.state_requirements.each do |requirement|
          requirement[:from].filter(state_names).each do |from|
            next if map.key?(from)

            to = if requirement[:to].is_a?(LoopbackMatcher)
                   from
                 else
                   requirement[:to].filter([from] | state_names).first
                 end
            map[from] = to if to
          end
        end
      end

      map
    end

    # Finds a pair of states from the initial set that can never be merged
    # into a single state.  A set of states is synchronizable if and only if
    # every pair within it is mergeable, so such a pair always exists when the
    # search fails.
    def find_unmergeable_pair(transitions)
      mergeable = {}
      queue = state_names.map { |state| [state, state] }
      queue.each { |pair| mergeable[pair] = true }

      until queue.empty?
        to_a, to_b = queue.shift
        state_names.each do |from_a|
          state_names.each do |from_b|
            pair = [from_a, from_b]
            next if mergeable[pair]

            merges = transitions.any? do |_event_name, map|
              map.fetch(from_a, from_a) == to_a && map.fetch(from_b, from_b) == to_b
            end
            next unless merges

            mergeable[pair] = true
            queue << pair
          end
        end
      end

      from_states.combination(2) do |pair|
        return pair unless mergeable[pair]
      end
      state_names.combination(2) do |pair|
        return pair unless mergeable[pair]
      end
      nil
    end
  end
end
