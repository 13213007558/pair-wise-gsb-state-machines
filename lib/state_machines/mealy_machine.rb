# frozen_string_literal: true

module StateMachines
  # A deterministic finite Mealy machine: every transition is labelled with
  # an input event and the output produced while taking it.
  #
  # Instances are typically produced by StateMachines::ActiveLearner, but the
  # class is a plain value object and can also be built by hand.
  class MealyMachine
    attr_reader :states, :inputs, :initial_state

    # transitions maps state => { input => [output, next_state] }
    def initialize(states:, inputs:, initial_state:, transitions:)
      @states = states.freeze
      @inputs = inputs.freeze
      @initial_state = initial_state
      @transitions = transitions.freeze
    end

    def output(state, input)
      transition_for(state, input).first
    end

    def next_state(state, input)
      transition_for(state, input).last
    end

    # Feeds +sequence+ of inputs starting +from+ a state and returns the
    # sequence of outputs produced by the machine.
    def run(sequence, from: @initial_state)
      state = from
      sequence.map do |input|
        output, state = *transition_for(state, input)
        output
      end
    end

    # Renders the machine in Graphviz DOT notation, handy for documenting a
    # learned model.
    def to_dot
      lines = ['digraph mealy {', '  rankdir=LR;', '  __start [shape=point];', "  __start -> #{initial_state};"]
      @states.each { |state| lines << "  #{state} [shape=circle];" }
      @transitions.each do |from, edges|
        edges.each do |input, (output, to)|
          lines << "  #{from} -> #{to} [label=\"#{input} / #{output}\"];"
        end
      end
      lines << '}'
      lines.join("\n")
    end

    private

    def transition_for(state, input)
      @transitions.fetch(state).fetch(input)
    end
  end
end
