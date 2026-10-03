# frozen_string_literal: true

module StateMachines
  # Analyzes a state machine as a fixed probabilistic model (a discrete-time
  # Markov chain).  Transitions defined with a :probability option (and an
  # optional :cost, defaulting to 1) describe the probability branches and
  # transition costs of the model.  No policy is learned or optimized here:
  # the probabilities are fixed and the analysis simply computes, for every
  # state:
  #
  # * the probability of ever reaching a given target state (absorption
  #   probability), and
  # * the expected cumulative cost incurred before reaching that target.
  #
  # If a state can get trapped forever in a closed loop that never reaches
  # the target (with positive probability), its expected completion cost and
  # time are reported as Float::INFINITY.  Absorption probabilities are still
  # computed for every state in that case.
  #
  # == Example
  #
  #   class Process
  #     state_machine initial: :running do
  #       event :finish do
  #         transition :running => :done, :probability => 0.8, :cost => 2
  #         transition :running => :retrying, :probability => 0.2, :cost => 1
  #       end
  #       event :retry do
  #         transition :retrying => :running, :probability => 1.0, :cost => 1
  #       end
  #     end
  #   end
  #
  #   machine = Process.state_machine
  #   analysis = StateMachines::ProbabilisticAnalysis.new(machine, target: :done)
  #   analysis.absorption_probability(:running)  # => 1.0
  #   analysis.expected_cost(:running)           # => 2.5
  class ProbabilisticAnalysis
    # Tolerance used when comparing probability sums and solved values
    TOLERANCE = 1e-9

    # Cost assumed for transitions that do not declare an explicit :cost
    DEFAULT_COST = 1.0

    # The machine being analyzed
    attr_reader :machine

    # The target (absorbing) state the analysis is computed against
    attr_reader :target

    def initialize(machine, target:)
      @machine = machine
      @target = target
      @states = machine.states.map(&:name)
      raise ArgumentError, "#{target.inspect} is not a known state in the #{machine.name.inspect} machine" unless @states.include?(target)

      @edges = build_edges
      validate_probability_sums!
    end

    # The list of state names included in the analysis
    attr_reader :states

    # The probabilistic edges leaving the given state.  Each edge is a hash
    # with :to, :probability, and :cost keys.
    def edges_for(state)
      @edges.fetch(state, []).map(&:dup)
    end

    # The sum of the probabilities of all transitions leaving each state.
    # Only states with at least one probabilistic transition are included.
    def probability_sums
      @edges.transform_values { |edges| edges.sum { |edge| edge[:probability] } }
    end

    # A hash mapping each state to the probability of ever reaching the
    # target state from it.  States that can never reach the target (for
    # example, states trapped in a closed loop) map to 0.0.
    def absorption_probabilities
      @absorption_probabilities ||= compute_absorption_probabilities
    end

    # The probability of ever reaching the target state from the given state
    def absorption_probability(state)
      absorption_probabilities.fetch(state)
    end

    # A hash mapping each state to the expected cumulative cost incurred
    # before reaching the target state.  The expectation is
    # Float::INFINITY for any state that has a positive-probability path
    # that never reaches the target (such as a path trapped in a closed
    # loop).
    def expected_costs
      @expected_costs ||= compute_expectations { |edge| edge[:cost] }
    end

    # The expected cumulative cost of reaching the target from the given
    # state, or Float::INFINITY if the target may never be reached
    def expected_cost(state)
      expected_costs.fetch(state)
    end

    # A hash mapping each state to the expected number of transitions
    # (completion time) before reaching the target state.  Like
    # #expected_costs, values are Float::INFINITY when the target is not
    # reached with probability 1.
    def expected_times
      @expected_times ||= compute_expectations { 1.0 }
    end

    # The expected number of transitions needed to reach the target from
    # the given state, or Float::INFINITY if the target may never be reached
    def expected_time(state)
      expected_times.fetch(state)
    end

    private

    # Expands the probabilistic branches of every event into concrete
    # from/to edges, keyed by the from state
    def build_edges
      edges = Hash.new { |hash, key| hash[key] = [] }
      machine.events.each do |event|
        event.branches.each do |branch|
          next if branch.probability.nil?

          validate_branch!(branch)
          branch.state_requirements.each do |requirement|
            requirement[:from].filter(states).each do |from|
              to_states(requirement, from).each do |to|
                edges[from] << { to: to, probability: branch.probability.to_f, cost: branch.cost.nil? ? DEFAULT_COST : branch.cost.to_f }
              end
            end
          end
        end
      end
      edges
    end

    # Resolves the concrete to states for a state requirement, expanding
    # loopback ("same") matchers against the current from state
    def to_states(requirement, from)
      matcher = requirement[:to]
      matcher.is_a?(LoopbackMatcher) ? [from] : matcher.filter(states)
    end

    def validate_branch!(branch)
      probability = branch.probability
      unless probability.is_a?(Numeric) && probability.positive? && probability <= 1
        raise ArgumentError, "Transition probability must be a number in (0, 1], got #{probability.inspect}"
      end
      return if branch.cost.nil? || (branch.cost.is_a?(Numeric) && !branch.cost.negative?)

      raise ArgumentError, "Transition cost must be a non-negative number, got #{branch.cost.inspect}"
    end

    # Every state with outgoing probabilistic transitions must distribute a
    # total probability of 1 across them
    def validate_probability_sums!
      invalid = probability_sums.reject { |_state, sum| (sum - 1.0).abs <= TOLERANCE }
      return if invalid.empty?

      details = invalid.map { |state, sum| "#{state.inspect} (sums to #{sum})" }.join(', ')
      raise ArgumentError, "Probabilities of transitions leaving #{details} must sum to 1"
    end

    # The set of states that can reach the target through probabilistic edges
    def states_reaching_target
      reachable = [target]
      visited = { target => true }
      until reachable.empty?
        current = reachable.pop
        @edges.each do |from, edges|
          next if visited[from]

          if edges.any? { |edge| edge[:to] == current }
            visited[from] = true
            reachable << from
          end
        end
      end
      visited.keys
    end

    def compute_absorption_probabilities
      reachable = states_reaching_target
      probabilities = {}
      states.each { |state| probabilities[state] = 0.0 }
      probabilities[target] = 1.0
      unknowns = reachable - [target]
      return probabilities if unknowns.empty?

      index = unknowns.each_with_index.to_h
      size = unknowns.size
      matrix = Array.new(size) { Array.new(size + 1, 0.0) }
      unknowns.each_with_index do |state, row|
        matrix[row][row] = 1.0
        @edges.fetch(state, []).each do |edge|
          if edge[:to] == target
            matrix[row][size] += edge[:probability]
          elsif (column = index[edge[:to]])
            matrix[row][column] -= edge[:probability]
          end
        end
      end

      solve(matrix).each_with_index do |value, row|
        probabilities[unknowns[row]] = value.clamp(0.0, 1.0)
      end
      probabilities
    end

    # Solves expected cumulative costs for the states that reach the target
    # with probability 1; every other state gets Float::INFINITY
    def compute_expectations(&cost_of)
      probabilities = absorption_probabilities
      expectations = {}
      states.each { |state| expectations[state] = state == target ? 0.0 : Float::INFINITY }

      certain = states.select { |state| state != target && probabilities[state] >= 1.0 - TOLERANCE }
      return expectations if certain.empty?

      index = certain.each_with_index.to_h
      size = certain.size
      matrix = Array.new(size) { Array.new(size + 1, 0.0) }
      certain.each_with_index do |state, row|
        matrix[row][row] = 1.0
        @edges.fetch(state, []).each do |edge|
          matrix[row][size] += edge[:probability] * cost_of.call(edge)
          matrix[row][index[edge[:to]]] -= edge[:probability] if index[edge[:to]]
        end
      end

      solve(matrix).each_with_index do |value, row|
        expectations[certain[row]] = value
      end
      expectations
    end

    # Solves an n-by-(n+1) augmented linear system by Gaussian elimination
    # with partial pivoting
    def solve(matrix)
      size = matrix.size
      size.times do |column|
        pivot = (column...size).max_by { |row| matrix[row][column].abs }
        raise Error, "Cannot solve probabilistic model for target #{target.inspect}: singular system" if matrix[pivot][column].abs < TOLERANCE

        matrix[column], matrix[pivot] = matrix[pivot], matrix[column]
        (column + 1...size).each do |row|
          factor = matrix[row][column] / matrix[column][column]
          (column..size).each { |cell| matrix[row][cell] -= factor * matrix[column][cell] }
        end
      end

      solution = Array.new(size, 0.0)
      (size - 1).downto(0) do |row|
        known = (row + 1...size).sum { |column| matrix[row][column] * solution[column] }
        solution[row] = (matrix[row][size] - known) / matrix[row][row]
      end
      solution
    end
  end
end
