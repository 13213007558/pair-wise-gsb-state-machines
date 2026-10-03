# frozen_string_literal: true

module StateMachines
  # Provides offline probabilistic analysis of a state machine's transition
  # graph.  Probabilistic branches (a from/to state pair annotated with a
  # fixed probability and a transition cost) are layered on top of the
  # machine's known states, turning it into a discrete-time Markov chain that
  # can be analyzed without ever running the machine.
  #
  # The model is *fixed*: probabilities and costs are given up front and are
  # never learned or optimized.  The analysis answers two questions for a
  # chosen terminal (target) state:
  #
  # * What is the probability of eventually reaching the target from each
  #   state (absorption probabilities)?
  # * What is the expected cumulative cost (e.g. completion time, when every
  #   branch costs 1) of reaching the target from each state?
  #
  # If a state can get trapped forever in a closed loop that never reaches
  # the target (with positive probability), its expected cost is reported as
  # +Float::INFINITY+.  Absorption probabilities are always computed, even
  # for states whose expected cost is infinite.
  #
  # == Example
  #
  #   machine = StateMachines::Machine.new(Class.new)
  #   machine.state :start, :spin_a, :spin_b, :done
  #
  #   analysis = StateMachines::ProbabilisticAnalysis.new(machine)
  #   analysis.branch from: :start, to: :done, probability: 0.5, cost: 2
  #   analysis.branch from: :start, to: :spin_a, probability: 0.5
  #   analysis.branch from: :spin_a, to: :spin_b, probability: 1.0
  #   analysis.branch from: :spin_b, to: :spin_a, probability: 1.0
  #
  #   analysis.absorption_probabilities(to: :done)
  #   # => {start: 0.5, spin_a: 0.0, spin_b: 0.0, done: 1.0}
  #   analysis.expected_costs(to: :done)
  #   # => {start: Infinity, spin_a: Infinity, spin_b: Infinity, done: 0.0}
  class ProbabilisticAnalysis
    # Tolerance used when verifying that per-state probabilities sum to 1
    TOLERANCE = 1e-9

    # The machine whose state space is being analyzed
    attr_reader :machine

    # The probabilistic branches added to this analysis.  Each branch is a
    # hash of +:from+, +:to+, +:probability+, and +:cost+.
    attr_reader :branches

    # Creates a new offline probabilistic analysis for the given machine.
    def initialize(machine)
      @machine = machine
      @branches = []
    end

    # Adds a probabilistic branch between two known states of the machine.
    #
    # Options:
    # * <tt>:from</tt> - The state the branch leaves from (required)
    # * <tt>:to</tt> - The state the branch arrives at (required); may be the
    #   same as +:from+ to model a self-loop
    # * <tt>:probability</tt> - The fixed probability of taking this branch
    #   whenever the chain is in the +:from+ state (required, must be in
    #   <tt>(0, 1]</tt>)
    # * <tt>:cost</tt> - The cost incurred when this branch is taken
    #   (optional, defaults to 1.0 so that expected cost measures the number
    #   of transitions, i.e. completion time)
    def branch(from:, to:, probability:, cost: 1.0)
      probability = Float(probability)
      cost = Float(cost)

      raise ArgumentError, "probability must be in (0, 1], got #{probability}" unless probability.positive? && probability <= 1.0
      raise ArgumentError, "cost must be non-negative, got #{cost}" if cost.negative?

      @branches << { from: from.to_sym, to: to.to_sym, probability: probability, cost: cost }
      self
    end

    # The sum of outgoing branch probabilities for each state that has at
    # least one branch.  States without branches are absorbing and do not
    # appear in this hash.
    def outgoing_probability_sums
      sums = Hash.new(0.0)
      @branches.each { |branch| sums[branch[:from]] += branch[:probability] }
      sums
    end

    # Validates the model:
    # * every branch endpoint is a known state of the machine
    # * every state with outgoing branches has probabilities summing to 1
    #
    # Raises ArgumentError if the model is invalid.  This is called
    # automatically by the analysis methods.
    def validate!
      unknown = @branches.flat_map { |branch| [branch[:from], branch[:to]] }.uniq - state_names
      raise ArgumentError, "unknown state(s): #{unknown.map(&:inspect).join(', ')}" unless unknown.empty?

      outgoing_probability_sums.each do |state, sum|
        next if (sum - 1.0).abs <= TOLERANCE

        raise ArgumentError, "outgoing probabilities for #{state.inspect} sum to #{sum}, expected 1.0"
      end
      true
    end

    # Computes, for every state, the probability of eventually reaching the
    # +to+ state.  Returns a hash of <tt>{state => probability}</tt>.  The
    # target itself always has probability 1; states that cannot reach the
    # target at all have probability 0.
    def absorption_probabilities(to:)
      validate!
      target = target_state(to)

      reachable = states_reaching(target)
      result = {}
      state_names.each { |state| result[state] = 0.0 unless reachable.include?(state) }
      result[target] = 1.0

      transient = reachable - [target]
      return result if transient.empty?

      vector = solve_over(transient) do |state, row, rhs|
        each_branch_from(state) do |branch|
          if branch[:to] == target
            rhs << branch[:probability]
          elsif reachable.include?(branch[:to])
            row[transient.index(branch[:to])] += branch[:probability]
          end
        end
      end

      transient.each_with_index { |state, index| result[state] = vector[index] }
      result
    end

    # Computes, for every state, the expected cumulative cost incurred before
    # reaching the +to+ state.  Returns a hash of <tt>{state => cost}</tt>.
    # The target itself has cost 0.
    #
    # States that can get trapped forever in a closed loop that never reaches
    # the target (with positive probability) have an expected cost of
    # +Float::INFINITY+.
    def expected_costs(to:)
      validate!
      target = target_state(to)

      reachable = states_reaching(target)
      trapped = states_reaching_trapped(target, reachable)

      result = {}
      state_names.each { |state| result[state] = Float::INFINITY if trapped.include?(state) || !reachable.include?(state) }
      result[target] = 0.0

      good = reachable - trapped - [target]
      return result if good.empty?

      vector = solve_over(good) do |state, row, rhs|
        expected_step_cost = 0.0
        each_branch_from(state) do |branch|
          expected_step_cost += branch[:probability] * branch[:cost]
          row[good.index(branch[:to])] += branch[:probability] if good.include?(branch[:to])
        end
        rhs << expected_step_cost
      end

      good.each_with_index { |state, index| result[state] = vector[index] }
      result
    end

    # The probability of eventually reaching +to+ from +from+.
    def absorption_probability(from:, to:)
      absorption_probabilities(to: to)[from.to_sym]
    end

    # The expected cumulative cost of reaching +to+ from +from+.
    def expected_cost(from:, to:)
      expected_costs(to: to)[from.to_sym]
    end

    private

    def state_names
      @state_names ||= machine.states.map(&:name).compact
    end

    def target_state(to)
      target = to.to_sym
      raise ArgumentError, "unknown target state: #{target.inspect}" unless state_names.include?(target)

      target
    end

    def each_branch_from(state)
      @branches.each { |branch| yield branch if branch[:from] == state }
    end

    # The set of states that can reach the target via one or more branches
    # (including the target itself).
    def states_reaching(target)
      reverse = Hash.new { |hash, key| hash[key] = [] }
      @branches.each { |branch| reverse[branch[:to]] << branch[:from] }

      reachable = [target]
      queue = [target]
      until queue.empty?
        reverse[queue.shift].each do |state|
          next if reachable.include?(state)

          reachable << state
          queue << state
        end
      end
      reachable
    end

    # The set of states that, with positive probability, can wander into a
    # state from which the target is unreachable -- without passing through
    # the target first.  These are the states that can get trapped forever
    # in a closed loop (e.g. a bad cycle or a dead-end absorbing state).
    def states_reaching_trapped(target, reachable)
      reverse = Hash.new { |hash, key| hash[key] = [] }
      @branches.each { |branch| reverse[branch[:to]] << branch[:from] unless branch[:from] == target }

      trapped = state_names - reachable
      queue = trapped.dup
      until queue.empty?
        reverse[queue.shift].each do |state|
          next if state == target || trapped.include?(state)

          trapped << state
          queue << state
        end
      end
      trapped
    end

    # Solves the linear system (I - Q) x = rhs over the given states, where
    # the block fills in each row of Q and the right-hand side entry for a
    # state.  Returns the solution vector in the same order as +states+.
    def solve_over(states)
      size = states.length
      coefficients = Array.new(size) { Array.new(size, 0.0) }
      rhs = Array.new(size, 0.0)

      states.each_with_index do |state, index|
        row = Array.new(size, 0.0)
        entries = []
        yield state, row, entries
        coefficients[index] = row.map { |value| -value }
        rhs[index] = entries.sum
      end

      size.times { |index| coefficients[index][index] += 1.0 }
      solve_linear(coefficients, rhs)
    end

    # Solves a square linear system by Gaussian elimination with partial
    # pivoting.  The coefficient matrix is guaranteed to be non-singular for
    # the transient subchains produced by this analysis.
    def solve_linear(coefficients, rhs)
      size = rhs.length
      size.times do |col|
        pivot = (col...size).max_by { |row| coefficients[row][col].abs }
        raise Error.new(nil, 'cannot solve probabilistic model: singular transition system') if coefficients[pivot][col].abs <= TOLERANCE

        coefficients[col], coefficients[pivot] = coefficients[pivot], coefficients[col]
        rhs[col], rhs[pivot] = rhs[pivot], rhs[col]

        (col + 1...size).each do |row|
          factor = coefficients[row][col] / coefficients[col][col]
          next if factor.zero?

          (col...size).each { |k| coefficients[row][k] -= factor * coefficients[col][k] }
          rhs[row] -= factor * rhs[col]
        end
      end

      solution = Array.new(size, 0.0)
      (size - 1).downto(0) do |row|
        remaining = (row + 1...size).sum { |k| coefficients[row][k] * solution[k] }
        solution[row] = (rhs[row] - remaining) / coefficients[row][row]
      end
      solution
    end
  end
end
