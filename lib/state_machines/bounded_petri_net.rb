# frozen_string_literal: true

module StateMachines
  # A place/transition Petri net with finite place capacities.
  module BoundedPetriNet
    # Raised when a Petri net definition is invalid.
    class DefinitionError < ArgumentError; end

    # Raised when a transition cannot fire from a marking.
    class TransitionNotEnabled < StandardError; end

    # A place and its maximum token capacity.
    Place = Struct.new(:name, :capacity, keyword_init: true)

    # A transition with weighted input, output, and read-only arcs.
    Transition = Struct.new(:name, :inputs, :outputs, :read_arcs, keyword_init: true)

    # An immutable, integer-valued mapping from place names to token counts.
    class Marking
      include Enumerable

      def initialize(values = {})
        values.each do |place, count|
          assert_count(count, place)
        end
        @values = values.transform_keys(&:to_sym)
                       .transform_values(&:to_i)
                       .reject { |_place, count| count.zero? }
                       .freeze
      end

      def [](place)
        @values.fetch(place.to_sym, 0)
      end

      def places
        @values.keys
      end

      def each(&block)
        @values.each(&block)
      end

      def to_h
        @values.dup
      end

      def total_tokens
        @values.values.sum
      end

      def with(changes)
        next_values = to_h
        changes.each do |place, delta|
          place = place.to_sym
          next_count = self[place] + delta
          assert_count(next_count, place)
          next_values[place] = next_count
        end
        Marking.new(next_values)
      end

      def ==(other)
        other.is_a?(Marking) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        [Marking, @values].hash
      end

      def inspect
        "#<#{self.class} #{@values.inspect}>"
      end

      private

      def assert_count(count, place)
        return if count.is_a?(Integer) && count >= 0

        raise ArgumentError, "Token count for #{place.inspect} must be a non-negative integer"
      end
    end

    # The result of an offline reachability search.
    class AnalysisResult
      attr_reader :reachable_markings, :deadlock_markings, :complete

      def initialize(reachable_markings, deadlock_markings, complete)
        @reachable_markings = reachable_markings.freeze
        @deadlock_markings = deadlock_markings.freeze
        @complete = complete
        freeze
      end

      def complete?
        complete
      end

      def incomplete?
        !complete?
      end

      def deadlock?
        !deadlock_markings.empty?
      end
    end

    # Defines and evaluates a bounded place/transition net.
    class Net
      attr_reader :places, :transitions, :initial_marking

      def initialize(initial_marking: {}, max_states: 1000)
        @places = {}
        @transitions = {}
        @initial_marking = Marking.new(initial_marking)
        @max_states = max_states
      end

      def self.define(initial_marking: {}, &block)
        net = new(initial_marking: initial_marking)
        net.instance_eval(&block) if block
        net.validate!
        net
      end

      def place(name, capacity:)
        unless capacity.is_a?(Integer) && capacity >= 0
          raise DefinitionError, "Capacity for #{name.inspect} must be a non-negative integer"
        end
        if @places.key?(name)
          raise DefinitionError, "Place #{name.inspect} is already defined"
        end

        @places[name] = Place.new(name: name, capacity: capacity)
      end

      def transition(name, inputs: {}, outputs: {}, read_arcs: {})
        if @transitions.key?(name)
          raise DefinitionError, "Transition #{name.inspect} is already defined"
        end

        [inputs, outputs, read_arcs].each { |arcs| validate_arc_weights(arcs, name) }
        @transitions[name] = Transition.new(
          name: name,
          inputs: normalize_arcs(inputs),
          outputs: normalize_arcs(outputs),
          read_arcs: normalize_arcs(read_arcs)
        )
      end

      def validate!
        ensure_at_least_one_place
        ensure_known_places(@initial_marking.places, 'initial marking')
        ensure_marking_within_capacity(@initial_marking, 'initial marking')
        @transitions.each_value do |transition|
          ensure_at_least_one_arc(transition)
          ensure_known_places(transition.inputs.keys, "transition #{transition.name.inspect}")
          ensure_known_places(transition.outputs.keys, "transition #{transition.name.inspect}")
          ensure_known_places(transition.read_arcs.keys, "transition #{transition.name.inspect}")
        end
        true
      end

      def enabled_transitions(marking = @initial_marking)
        marking = prepare_marking(marking)
        @transitions.values.select { |transition| enabled?(transition, marking) }.map(&:name)
      end

      def enabled?(transition_name, marking = @initial_marking)
        transition = fetch_transition(transition_name)
        enabled?(transition, prepare_marking(marking))
      end

      def fire(transition_name, marking = @initial_marking)
        transition = fetch_transition(transition_name)
        marking = prepare_marking(marking)
        return nil unless enabled?(transition, marking)

        successor(transition, marking)
      end

      def fire!(transition_name, marking = @initial_marking)
        transition = fetch_transition(transition_name)
        marking = prepare_marking(marking)
        unless enabled?(transition, marking)
          raise TransitionNotEnabled,
                "Transition #{transition_name.inspect} is not enabled from #{marking.inspect}"
        end

        successor(transition, marking)
      end

      def successor_markings(marking = @initial_marking)
        marking = prepare_marking(marking)
        enabled_transitions(marking).map do |transition_name|
          fire!(transition_name, marking)
        end
      end

      def analyze(initial_marking = @initial_marking, max_states: @max_states)
        initial_marking = prepare_marking(initial_marking)
        unless max_states.is_a?(Integer) && max_states.positive?
          raise ArgumentError, 'max_states must be a positive integer'
        end

        visited = {}
        queue = [initial_marking]
        visited[initial_marking] = true
        deadlocks = []
        complete = true

        until queue.empty?
          current = queue.shift
          successors = successor_markings(current)
          if successors.empty?
            deadlocks << current
            yield(current, nil) if block_given?
          else
            successors.each do |successor|
              yield(current, successor) if block_given?
              next if visited.key?(successor)
              if visited.size >= max_states
                complete = false
                next
              end
              visited[successor] = true
              queue << successor
            end
          end
        end

        reachable = visited.keys
        AnalysisResult.new(reachable, deadlocks, complete)
      end

      def reachable_markings(initial_marking = @initial_marking, max_states: @max_states)
        analyze(initial_marking, max_states: max_states).reachable_markings
      end

      def deadlock_markings(initial_marking = @initial_marking, max_states: @max_states)
        analyze(initial_marking, max_states: max_states).deadlock_markings
      end

      private

      def validate_arc_weights(arcs, transition_name)
        arcs.each do |place, weight|
          unless weight.is_a?(Integer) && weight.positive?
            raise DefinitionError,
                  "Arc weight from #{place.inspect} to #{transition_name.inspect} must be a positive integer"
          end
        end
      end

      def normalize_arcs(arcs)
        arcs.transform_keys(&:to_sym).freeze
      end

      def ensure_at_least_one_place
        return unless @places.empty?

        raise DefinitionError, 'Petri net must define at least one place'
      end

      def ensure_known_places(names, context)
        names.each do |name|
          next if @places.key?(name.to_sym)

          raise DefinitionError, "Unknown place #{name.inspect} referenced in #{context}"
        end
      end

      def ensure_marking_within_capacity(marking, context)
        @places.each do |name, place|
          next unless marking[name] > place.capacity

          raise DefinitionError,
                "Marking for #{name.inspect} exceeds capacity in #{context}"
        end
      end

      def ensure_at_least_one_arc(transition)
        return unless transition.inputs.empty? && transition.outputs.empty? && transition.read_arcs.empty?

        raise DefinitionError, "Transition #{transition.name.inspect} must have at least one arc"
      end

      def fetch_transition(name)
        @transitions.fetch(name.to_sym) do
          raise DefinitionError, "Unknown transition #{name.inspect}"
        end
      end

      def coerce_marking(marking)
        return marking if marking.is_a?(Marking)

        Marking.new(marking.transform_keys(&:to_sym))
      end

      def prepare_marking(marking)
        marking = coerce_marking(marking)
        ensure_known_places(marking.places, 'marking')
        ensure_marking_within_capacity(marking, 'marking')
        marking
      end

      def enabled?(transition, marking)
        transition.read_arcs.all? { |place, weight| marking[place] >= weight } &&
          transition.inputs.all? { |place, weight| marking[place] >= weight } &&
          fits_capacity?(marking, transition)
      end

      def fits_capacity?(marking, transition)
        @places.all? do |place_name, place|
          delta = transition.outputs.fetch(place_name, 0) - transition.inputs.fetch(place_name, 0)
          marking[place_name] + delta <= place.capacity
        end
      end

      def successor(transition, marking)
        changes = {}
        transition.inputs.each_key { |place| changes[place] = 0 }
        transition.outputs.each_key { |place| changes[place] = 0 }
        transition.inputs.each { |place, weight| changes[place] -= weight }
        transition.outputs.each { |place, weight| changes[place] += weight }
        marking.with(changes)
      end
    end
  end
end
