# frozen_string_literal: true

require 'test_helper'

class ActiveLearningMealyLearnerTest < StateMachinesTest
  def test_learns_mealy_model_with_process_local_oracle_and_reports_queries
    target = two_state_target

    result = StateMachines::ActiveLearning.learn(
      %i[go stop],
      reset: target.reset,
      step: target.step,
      equivalence_query: exhaustive_oracle(target, depth: 3)
    )

    assert result.equivalent?
    assert_equal :equivalent, result.stop_reason
    assert_equal %i[q0 q1], result.model.states
    assert_equal %i[ok], result.model.outputs_for(%i[go])
    assert_equal %i[ok stopped], result.model.outputs_for(%i[go stop])
    assert_equal %i[blocked], result.model.outputs_for(%i[stop])
    assert_predicate result.stats, :frozen?
    assert result.stats.total_queries.positive?
    assert_equal result.stats.membership_queries + result.stats.equivalence_queries,
                 result.stats.total_queries
  end

  def test_counterexample_refines_model_instead_of_accepting_the_sequence
    target = delayed_target
    oracle_calls = 0
    oracle = lambda do |hypothesis, _stats|
      oracle_calls += 1
      next %i[go go go] if oracle_calls == 1

      exhaustive_oracle(target, depth: 4).call(hypothesis)
    end

    result = StateMachines::ActiveLearning.learn(
      %i[go stop],
      reset: target.reset,
      step: target.step,
      equivalence_query: oracle
    )

    assert result.equivalent?
    assert_equal 1, result.stats.counterexamples
    assert_equal 2, result.stats.equivalence_queries
    assert_equal 3, result.model.states.length
    assert_equal %i[ok ok done], result.model.outputs_for(%i[go go go])
    assert_equal %i[waiting ok ok done], result.model.outputs_for(%i[stop go go go])
  end

  def test_reports_membership_query_limit_without_claiming_equivalence
    target = two_state_target

    result = StateMachines::ActiveLearning.learn(
      %i[go stop],
      reset: target.reset,
      step: target.step,
      equivalence_query: exhaustive_oracle(target, depth: 3),
      max_membership_queries: 2
    )

    refute result.equivalent?
    assert_nil result.model
    assert_equal :max_membership_queries, result.stop_reason
    assert_equal 2, result.stats.membership_queries
  end

  def test_rejects_counterexample_that_agrees_with_current_hypothesis
    target = two_state_target
    calls = 0
    oracle = lambda do |hypothesis, _stats|
      calls += 1
      next %i[stop] if calls == 1

      exhaustive_oracle(target, depth: 3).call(hypothesis)
    end

    result = StateMachines::ActiveLearning.learn(
      %i[go stop],
      reset: target.reset,
      step: target.step,
      equivalence_query: oracle
    )

    refute result.equivalent?
    assert_equal :invalid_counterexample, result.stop_reason
    assert_equal 0, result.stats.counterexamples
  end

  def test_rejects_events_outside_the_alphabet
    target = two_state_target

    assert_raises(ArgumentError) do
      StateMachines::ActiveLearning.learn(
        %i[go stop],
        reset: target.reset,
        step: target.step,
        equivalence_query: ->(_hypothesis, _stats) { %i[unknown] }
      )
    end
  end

  def test_exposes_learned_model_as_data_and_mermaid_document
    target = two_state_target

    result = StateMachines::ActiveLearning.learn(
      %i[go stop],
      reset: target.reset,
      step: target.step,
      equivalence_query: exhaustive_oracle(target, depth: 3)
    )

    data = result.model.to_h
    assert_equal :q0, data[:initial_state]
    assert_equal %i[go stop], data[:input_alphabet]
    assert_equal :ok, data[:transitions][:q0][:go][:output]
    assert_equal :q1, data[:transitions][:q0][:go][:next_state]
    assert_includes result.model.to_mermaid, 'stateDiagram-v2'
    assert_includes result.model.to_mermaid, 'q0 --> q1 : go / ok'
  end

  private

  Target = Struct.new(:reset, :step, keyword_init: true)

  def two_state_target
    state = :q0
    reset = -> { state = :q0 }
    step = lambda do |input|
      case [state, input]
      in [:q0, :go]
        state = :q1
        :ok
      in [:q0, :stop]
        :blocked
      in [:q1, :go]
        :ok
      in [:q1, :stop]
        state = :q0
        :stopped
      end
    end
    Target.new(reset: reset, step: step)
  end

  def delayed_target
    state = :q0
    reset = -> { state = :q0 }
    step = lambda do |input|
      case [state, input]
      in [:q0, :go] | [:q1, :go]
        state = state == :q0 ? :q1 : :q2
        :ok
      in [:q0, :stop] | [:q1, :stop]
        :waiting
      in [:q2, :go] | [:q2, :stop]
        :done
      end
    end
    Target.new(reset: reset, step: step)
  end

  def exhaustive_oracle(target, depth:)
    lambda do |hypothesis|
      counterexample = nil
      (0..depth).each do |length|
        %i[go stop].repeated_permutation(length).each do |sequence|
          target.reset.call
          actual = sequence.map { |event| target.step.call(event) }
          if actual != hypothesis.outputs_for(sequence)
            counterexample = sequence
            break
          end
        end
        break if counterexample
      end
      counterexample
    end
  end
end
