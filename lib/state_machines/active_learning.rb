# frozen_string_literal: true

module StateMachines
  module ActiveLearning
    Transition = Data.define(:source_state, :input, :output, :next_state)

    Trace = Data.define(:states, :outputs, :transitions)

    class QueryStats
      attr_accessor :membership_queries, :membership_steps,
                    :equivalence_queries, :counterexamples

      def initialize
        @membership_queries = 0
        @membership_steps = 0
        @equivalence_queries = 0
        @counterexamples = 0
      end

      def total_queries
        membership_queries + equivalence_queries
      end

      def to_h
        {
          membership_queries: membership_queries,
          membership_steps: membership_steps,
          equivalence_queries: equivalence_queries,
          counterexamples: counterexamples,
          total_queries: total_queries
        }
      end
    end

    class MealyMachine
      attr_reader :input_alphabet, :initial_state, :states, :transitions

      def initialize(input_alphabet:, initial_state:, transitions:)
        @input_alphabet = input_alphabet.dup.freeze
        @initial_state = initial_state
        @transitions = transitions.transform_values(&:freeze).freeze
        @states = (
          transitions.keys +
          transitions.values.flat_map { |edges| edges.values.map(&:next_state) }
        ).uniq.freeze

        validate_machine
      end

      def transition(state, input)
        edges = fetch_edges(state)
        edges.fetch(input) do
          raise ArgumentError, "Unknown input #{input.inspect} for state #{state.inspect}"
        end
      end

      def run(inputs)
        state = initial_state
        states = [state]
        outputs = []
        path = []

        Array(inputs).each do |input|
          edge = transition(state, input)
          path << edge
          outputs << edge.output
          state = edge.next_state
          states << state
        end

        Trace.new(states.freeze, outputs.freeze, path.freeze)
      end

      def outputs_for(inputs)
        run(inputs).outputs
      end

      def to_h
        edges = transitions.to_h do |state, state_edges|
          mapped = state_edges.to_h do |input, edge|
            [input, { output: edge.output, next_state: edge.next_state }]
          end
          [state, mapped]
        end

        {
          states: states.dup,
          initial_state: initial_state,
          input_alphabet: input_alphabet.dup,
          transitions: edges
        }
      end

      def to_mermaid
        lines = ['stateDiagram-v2', "    [*] --> #{initial_state}"]
        transitions.each do |_source, state_edges|
          state_edges.each_value do |edge|
            lines << format(
              '    %<source>s --> %<target>s : %<input>s / %<output>s',
              source: edge.source_state,
              target: edge.next_state,
              input: mermaid_label(edge.input),
              output: mermaid_label(edge.output)
            )
          end
        end
        lines.join("\n")
      end

      private

      def validate_machine
        unless states.include?(initial_state)
          raise ArgumentError, 'Initial state must be included in transitions'
        end

        states.each do |state|
          edges = fetch_edges(state)
          missing = input_alphabet - edges.keys
          unless missing.empty?
            raise ArgumentError, "Missing transitions from #{state.inspect} for #{missing.inspect}"
          end
          extra = edges.keys - input_alphabet
          unless extra.empty?
            raise ArgumentError, "Unknown transition inputs #{extra.inspect} from #{state.inspect}"
          end
        end
      end

      def fetch_edges(state)
        transitions.fetch(state) do
          raise ArgumentError, "Unknown state #{state.inspect}"
        end
      end

      def mermaid_label(value)
        case value
        when Symbol then value.to_s
        when String then value.inspect
        else value.inspect
        end
      end
    end

    class LearningResult
      attr_reader :model, :stats, :stop_reason, :iterations

      def initialize(model:, stats:, stop_reason:, iterations:)
        @model = model
        @stats = stats.dup
        @stats.freeze
        @stop_reason = stop_reason
        @iterations = iterations
        freeze
      end

      def equivalent?
        stop_reason == :equivalent
      end
    end

    class MealyLearner
      attr_reader :stats, :iterations

      def initialize(input_alphabet:, reset:, step:, equivalence_query: nil,
                     equivalence_oracle: nil, max_iterations: nil,
                     max_membership_queries: nil)
        @input_alphabet = normalize_alphabet(input_alphabet)
        @reset_callback = reset
        @step_callback = step
        @equivalence_callback = equivalence_query || equivalence_oracle
        @max_iterations = max_iterations
        @max_membership_queries = max_membership_queries

        validate_arguments

        @prefixes = [[]]
        @suffixes = input_alphabet.map { |input| [input] }
        @trace_cache = {}
        @stats = QueryStats.new
        @iterations = 0
      end

      def learn
        loop do
          return query_limit_result unless fill_table

          until closed? && consistent?
            refine_table
            return query_limit_result unless fill_table
          end

          hypothesis = build_hypothesis
          @iterations += 1
          stats.equivalence_queries += 1

          equivalence = invoke_equivalence_callback(hypothesis)
          if equivalent_response?(equivalence)
            return result(hypothesis, :equivalent)
          end

          counterexample = counterexample_from(equivalence)
          validate_counterexample(counterexample)
          actual_outputs = trace(counterexample)
          return query_limit_result if actual_outputs.nil?

          if actual_outputs == hypothesis.outputs_for(counterexample)
            return result(hypothesis, :invalid_counterexample)
          end

          stats.counterexamples += 1
          add_counterexample(counterexample)

          if @max_iterations && iterations >= @max_iterations
            return result(hypothesis, :max_iterations)
          end
        end
      end

      private

      attr_reader :input_alphabet

      def normalize_alphabet(alphabet)
        values = Array(alphabet)
        raise ArgumentError, 'Input alphabet cannot be empty' if values.empty?
        unless values.uniq.length == values.length
          raise ArgumentError, 'Input alphabet must contain unique values'
        end

        values.freeze
      end

      def validate_arguments
        unless @reset_callback.respond_to?(:call)
          raise ArgumentError, 'reset must respond to #call'
        end
        unless @step_callback.respond_to?(:call)
          raise ArgumentError, 'step must respond to #call'
        end
        unless @equivalence_callback.respond_to?(:call)
          raise ArgumentError, 'equivalence_query must respond to #call'
        end
      end

      def extended_prefixes
        @prefixes.flat_map do |prefix|
          input_alphabet.map { |input| prefix + [input] }
        end.uniq
      end

      def all_prefixes
        (@prefixes + extended_prefixes).uniq
      end

      def row(prefix)
        @suffixes.map { |suffix| suffix_outputs(prefix, suffix) }
      end

      def suffix_outputs(prefix, suffix)
        return [] if suffix.empty?

        outputs = trace(prefix + suffix)
        return nil if outputs.nil?

        outputs.last(suffix.length)
      end

      def trace(events)
        events = Array(events)
        return @trace_cache[events] if @trace_cache.key?(events)
        return nil if membership_limit_reached?

        @reset_callback.call
        outputs = events.map { |event| @step_callback.call(event) }
        @trace_cache[events] = outputs
        stats.membership_queries += 1
        stats.membership_steps += events.length
        outputs
      end

      def membership_limit_reached?
        @max_membership_queries &&
          stats.membership_queries >= @max_membership_queries
      end

      def fill_table
        @suffixes.each do |suffix|
          all_prefixes.each do |prefix|
            if suffix.empty?
              next if prefix.empty? || @trace_cache.key?(prefix)
              return false if trace(prefix).nil?
            else
              sequence = prefix + suffix
              next if @trace_cache.key?(sequence)
              return false if trace(sequence).nil?
            end
          end
        end
        true
      end

      def closed?
        state_rows = @prefixes.map { |prefix| row(prefix) }
        extended_prefixes.all? { |prefix| state_rows.include?(row(prefix)) }
      end

      def consistent?
        @prefixes.combination(2).each do |first, second|
          next unless row(first) == row(second)

          input_alphabet.each do |input|
            return false if row(first + [input]) != row(second + [input])
          end
        end
        true
      end

      def refine_table
        unclosed = extended_prefixes.find do |prefix|
          @prefixes.none? { |state_prefix| row(state_prefix) == row(prefix) }
        end

        if unclosed
          add_prefix(unclosed)
          return
        end

        @prefixes.combination(2).each do |first, second|
          next unless row(first) == row(second)

          input_alphabet.each do |input|
            first_extension = first + [input]
            second_extension = second + [input]
            next if row(first_extension) == row(second_extension)

            differing_suffix = @suffixes.find do |suffix|
              suffix_outputs(first_extension, suffix) != suffix_outputs(second_extension, suffix)
            end
            add_suffix([input] + differing_suffix.to_a)
            return
          end
        end
      end

      def add_prefix(prefix)
        @prefixes |= [prefix]
      end

      def add_suffix(suffix)
        @suffixes |= [suffix]
      end

      def add_counterexample(events)
        prefix = []
        Array(events).each do |input|
          prefix << input
          add_prefix(prefix)
        end

        0.upto(events.length - 1) do |index|
          add_suffix(events[index..])
        end
      end

      def build_hypothesis
        state_names = {}
        representatives = {}

        @prefixes.each do |prefix|
          state_row = row(prefix)
          next if representatives.key?(state_row)

          representatives[state_row] = prefix
          state_names[state_row] = "q#{state_names.length}".to_sym
        end

        transitions = {}
        state_names.each do |state_row, state|
          representative = representatives.fetch(state_row)
          transitions[state] = input_alphabet.to_h do |input|
            extension = representative + [input]
            edge = Transition.new(
              source_state: state,
              input: input,
              output: trace(extension).last,
              next_state: state_names.fetch(row(extension))
            )
            [input, edge]
          end
        end

        MealyMachine.new(
          input_alphabet: input_alphabet,
          initial_state: state_names.fetch(row([])),
          transitions: transitions
        )
      end

      def invoke_equivalence_callback(hypothesis)
        callback = @equivalence_callback
        arity = callback.respond_to?(:arity) ? callback.arity : 1
        arguments = [hypothesis, stats.dup.freeze]
        arguments = if arity.positive?
                      arguments.first(arity)
                    elsif arity.negative?
                      arguments
                    else
                      []
                    end
        callback.call(*arguments)
      end

      def equivalent_response?(response)
        response.nil? || response == true
      end

      def counterexample_from(response)
        if response.respond_to?(:counterexample) && response.counterexample
          return Array(response.counterexample)
        end
        if response.is_a?(Hash) && response.key?(:counterexample)
          return Array(response.fetch(:counterexample))
        end
        if response.respond_to?(:to_ary)
          return Array(response)
        end

        raise ArgumentError, 'Equivalence query must return true/nil or a counterexample sequence'
      end

      def validate_counterexample(events)
        invalid = events - input_alphabet
        return if invalid.empty?

        raise ArgumentError, "Counterexample contains unknown inputs #{invalid.inspect}"
      end

      def result(model, reason)
        LearningResult.new(
          model: model,
          stats: stats,
          stop_reason: reason,
          iterations: iterations
        )
      end

      def query_limit_result
        result(nil, :max_membership_queries)
      end
    end

    def self.learn(input_alphabet = nil, reset:, step:, equivalence_query: nil,
                   equivalence_oracle: nil, max_iterations: nil,
                   max_membership_queries: nil, &block)
      equivalence_query ||= block || equivalence_oracle
      MealyLearner.new(
        input_alphabet: input_alphabet,
        reset: reset,
        step: step,
        equivalence_query: equivalence_query,
        max_iterations: max_iterations,
        max_membership_queries: max_membership_queries
      ).learn
    end
  end
end
