# frozen_string_literal: true

module StateMachines
  # A bounded Petri net with weighted input, output, and read-only arcs.
  module PetriNet
    class Error < StandardError; end

    class InvalidDefinition < Error; end

    class UnknownTransition < Error; end

    class TransitionNotEnabled < Error; end

    class Place
      attr_reader :name, :capacity, :initial_tokens

      def initialize(name, capacity, initial_tokens)
        @name = name.to_sym
        @capacity = capacity
        @initial_tokens = initial_tokens
        validate!
      end

      private

      def validate!
        unless capacity.is_a?(Integer) && capacity.positive?
          raise InvalidDefinition, "Place #{name.inspect} capacity must be a positive Integer"
        end

        unless initial_tokens.is_a?(Integer) && initial_tokens >= 0
          raise InvalidDefinition, "Place #{name.inspect} tokens must be a non-negative Integer"
        end

        return if initial_tokens <= capacity

        raise InvalidDefinition, "Place #{name.inspect} cannot contain #{initial_tokens} tokens with capacity #{capacity}"
      end
    end

    class Transition
      attr_reader :name, :input, :output, :read

      def initialize(name, input:, output:, read:)
        @name = name.to_sym
        @input = normalize_arcs(input)
        @output = normalize_arcs(output)
        @read = normalize_arcs(read)
        validate!
      end

      def enabled?(marking, places)
        input.all? { |place_name, weight| marking.fetch(place_name) >= weight } &&
          read.all? { |place_name, weight| marking.fetch(place_name) >= weight } &&
          fits_capacity?(marking, places)
      end

      def fire(marking, places)
        return nil unless enabled?(marking, places)

        marking.each_with_object({}) do |(place_name, tokens), next_marking|
          next_marking[place_name] = tokens - input.fetch(place_name, 0) + output.fetch(place_name, 0)
        end.freeze
      end

      private

      def fits_capacity?(marking, places)
        output.all? do |place_name, weight|
          marking.fetch(place_name) - input.fetch(place_name, 0) + weight <= places.fetch(place_name).capacity
        end
      end

      def normalize_arcs(arcs)
        arcs.to_h { |place_name, weight| [place_name.to_sym, weight] }.freeze
      end

      def validate!
        [input, output, read].each do |arcs|
          arcs.each_value do |weight|
            unless weight.is_a?(Integer) && weight.positive?
              raise InvalidDefinition, "Transition #{name.inspect} arc weights must be positive Integers"
            end
          end
        end
      end
    end

    class BoundedPetriNet
      attr_reader :places, :transitions, :initial_marking, :marking

      def initialize(initial_marking: {}, &definition)
        @places = {}
        @transitions = {}
        @declared_initial_marking = initial_marking.to_h { |name, tokens| [name.to_sym, tokens] }
        @mutex = Mutex.new

        instance_exec(&definition) if definition
        validate_definition!

        @initial_marking = build_initial_marking.freeze
        @marking = @initial_marking.dup.freeze
      end

      def place(name, capacity:, tokens: 0)
        initial_tokens = @declared_initial_marking.key?(name.to_sym) ? @declared_initial_marking[name.to_sym] : tokens
        place = Place.new(name, capacity, initial_tokens)
        places[place.name] = place
        place.name
      end

      def transition(name, input: {}, output: {}, read: nil, readonly: nil, read_only: nil)
        read_arcs = resolve_read_arcs(name, read, readonly, read_only)
        transition = Transition.new(name, input: input, output: output, read: read_arcs)
        transitions[transition.name] = transition
        transition.name
      end

      def enabled?(transition_name)
        transition = transitions[transition_name.to_sym]
        return false unless transition

        @mutex.synchronize { transition.enabled?(marking, places) }
      end

      def enabled_transitions
        @mutex.synchronize do
          transitions.each_value.select { |transition| transition.enabled?(marking, places) }.map(&:name)
        end
      end

      def fire(transition_name)
        @mutex.synchronize do
          transition = transitions[transition_name.to_sym]
          return false unless transition

          next_marking = transition.fire(marking, places)
          return false unless next_marking

          @marking = next_marking
          true
        end
      end

      def fire!(transition_name)
        name = transition_name.to_sym
        transition = transitions.fetch(name) do
          raise UnknownTransition, "Unknown transition #{name.inspect}"
        end

        @mutex.synchronize do
          next_marking = transition.fire(marking, places)
          unless next_marking
            raise TransitionNotEnabled, "Transition #{name.inspect} is not enabled in #{marking.inspect}"
          end

          @marking = next_marking
          true
        end
      end

      def reset!
        @mutex.synchronize { @marking = @initial_marking.dup.freeze }
        marking
      end

      def token_count(current_marking = marking)
        current_marking.values.sum
      end

      def analyze_reachability(state_limit: 1000)
        unless state_limit.is_a?(Integer) && state_limit.positive?
          raise InvalidDefinition, 'state_limit must be a positive Integer'
        end

        @mutex.synchronize { ReachabilityAnalyzer.new(self, state_limit).analyze }
      end

      private

      def resolve_read_arcs(name, read, readonly, read_only)
        values = [read, readonly, read_only].compact
        return values.first if values.size == 1

        raise InvalidDefinition, "Use one read arc keyword for transition #{name.inspect}" unless values.empty?

        {}
      end

      def build_initial_marking
        places.each_value.with_object({}) do |place, marking|
          marking[place.name] = place.initial_tokens
        end
      end

      def validate_definition!
        validate_places!
        transitions.each_value do |transition|
          validate_arcs!(transition, transition.input)
          validate_arcs!(transition, transition.output)
          validate_arcs!(transition, transition.read)
        end
      end

      def validate_places!
        unknown_tokens = @declared_initial_marking.keys - places.keys
        return if unknown_tokens.empty?

        raise InvalidDefinition, "Initial marking references unknown places: #{unknown_tokens.join(', ')}"
      end

      def validate_arcs!(transition, arcs)
        unknown_places = arcs.keys - places.keys
        return if unknown_places.empty?

        raise InvalidDefinition, "Transition #{transition.name.inspect} references unknown places: #{unknown_places.join(', ')}"
      end
    end

    class ReachabilityAnalysis
      attr_reader :reachable_markings, :deadlock_markings, :state_limit, :states_visited

      def initialize(reachable_markings, deadlock_markings, state_limit, complete)
        @reachable_markings = reachable_markings
        @deadlock_markings = deadlock_markings
        @state_limit = state_limit
        @complete = complete
        @states_visited = reachable_markings.size
      end

      def complete?
        @complete
      end

      def incomplete?
        !complete?
      end

      def deadlocked?
        complete? && deadlock_markings.any?
      end
    end

    class ReachabilityAnalyzer
      def initialize(net, state_limit)
        @net = net
        @state_limit = state_limit
        @reachable = []
        @seen = {}
        @deadlocks = []
        @complete = true
      end

      def analyze
        enqueue(@net.marking)
        queue = [@net.marking]

        until queue.empty?
          current = queue.shift
          successors = enabled_successors(current)

          if successors.empty?
            @deadlocks << current
          else
            successors.each do |successor|
              next if seen?(successor)

              if @reachable.size >= @state_limit
                return truncated_analysis
              end

              enqueue(successor)
              queue << successor
            end
          end

          return truncated_analysis if @reachable.size >= @state_limit
        end

        analysis
      end

      private

      def enabled_successors(marking)
        @net.transitions.each_value.filter_map do |transition|
          transition.fire(marking, @net.places)
        end
      end

      def enqueue(marking)
        @seen[marking] = true
        @reachable << marking
      end

      def seen?(marking)
        @seen.key?(marking)
      end

      def analysis
        ReachabilityAnalysis.new(@reachable.freeze, @deadlocks.freeze, @state_limit, @complete)
      end

      def truncated_analysis
        @complete = false
        analysis
      end
    end
  end
end
