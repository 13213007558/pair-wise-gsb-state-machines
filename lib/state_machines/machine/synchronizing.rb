# frozen_string_literal: true

module StateMachines
  class Machine
    module Synchronizing
      # Finds the shortest sequence of events that drives this machine into a
      # single known state, regardless of which state it is currently in.
      # This is useful when the current state of an object has been lost (for
      # example, after a device reconnects) but events can still be sent to
      # it.
      #
      # == Examples
      #
      #   sequence = machine.synchronizing_sequence
      #   sequence.synchronized?     # => true
      #   sequence.events            # => [:shift_up, :shift_up]
      #   sequence.state             # => :driving
      #
      #   # The current state is only known to be within a subset of states
      #   machine.synchronizing_sequence(from: [:idling, :driving])
      #
      #   # Exclude events that cannot be fired by the caller
      #   machine.synchronizing_sequence(except: :repair)
      #
      #   # Machines that cannot be synchronized expose a state pair that can
      #   # never be merged
      #   sequence = machine.synchronizing_sequence
      #   sequence.synchronized?     # => false
      #   sequence.unmergeable_pair  # => [:a, :b]
      #
      # Configuration options:
      # * <tt>:from</tt> - One or more states the machine may currently be in.
      #   Defaults to all states of the machine.
      # * <tt>:except</tt> - One or more events that cannot be fired and must
      #   be excluded from the sequence.
      #
      # The machine's transitions must be unguarded; an ArgumentError is
      # raised if any usable event has guarded transitions.
      def synchronizing_sequence(options = {})
        SynchronizingSequence.new(self, options)
      end
    end
  end
end
