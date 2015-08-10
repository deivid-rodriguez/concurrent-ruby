require 'concurrent/concern/dereferenceable'
require 'concurrent/synchronization'

module Concurrent

  # An `MVar` is a synchronized single element container. They are empty or
  # contain one item. Taking a value from an empty `MVar` blocks, as does
  # putting a value into a full one. You can either think of them as blocking
  # queue of length one, or a special kind of mutable variable.
  #
  # On top of the fundamental `#put` and `#take` operations, we also provide a
  # `#mutate` that is atomic with respect to operations on the same instance.
  # These operations all support timeouts.
  #
  # We also support non-blocking operations `#try_put!` and `#try_take!`, a
  # `#set!` that ignores existing values, a `#value` that returns the value
  # without removing it or returns `MVar::EMPTY`, and a `#modify!` that yields
  # `MVar::EMPTY` if the `MVar` is empty and can be used to set `MVar::EMPTY`.
  # You shouldn't use these operations in the first instance.
  #
  # `MVar` is a [Dereferenceable](Dereferenceable).
  #
  # `MVar` is related to M-structures in Id, `MVar` in Haskell and `SyncVar` in Scala.
  #
  # Note that unlike the original Haskell paper, our `#take` is blocking. This is how
  # Haskell and Scala do it today.
  #
  # @!macro copy_options
  #
  # ## See Also
  #
  # 1. P. Barth, R. Nikhil, and Arvind. [M-Structures: Extending a parallel, non- strict, functional language with state](http://dl.acm.org/citation.cfm?id=652538). In Proceedings of the 5th
  #    ACM Conference on Functional Programming Languages and Computer Architecture (FPCA), 1991.
  #
  # 2. S. Peyton Jones, A. Gordon, and S. Finne. [Concurrent Haskell](http://dl.acm.org/citation.cfm?id=237794).
  #    In Proceedings of the 23rd Symposium on Principles of Programming Languages
  #    (PoPL), 1996.
  class MVar < Synchronization::Object
    include Concern::Dereferenceable

    # Unique value that represents that an `MVar` was empty
    EMPTY = Object.new

    # Unique value that represents that an `MVar` timed out before it was able
    # to produce a value.
    TIMEOUT = Object.new

    # Create a new `MVar`, either empty or with an initial value.
    #
    # @param [Hash] opts the options controlling how the future will be processed
    #
    # @!macro deref_options
    def initialize(value = EMPTY, opts = {})
      super()
      synchronize { ns_initialize(value, opts) }
    end

    # Remove the value from an `MVar`, leaving it empty, and blocking if there
    # isn't a value. A timeout can be set to limit the time spent blocked, in
    # which case it returns `TIMEOUT` if the time is exceeded.
    # @return [Object] the value that was taken, or `TIMEOUT`
    def take(timeout = nil)
      synchronize do
        wait_for_full(timeout)

        # If we timed out we'll still be empty
        if ns_full?
          value = @value
          @value = EMPTY
          @empty_condition.ns_signal
          apply_deref_options(value)
        else
          TIMEOUT
        end
      end
    end

    # Put a value into an `MVar`, blocking if there is already a value until
    # it is empty. A timeout can be set to limit the time spent blocked, in
    # which case it returns `TIMEOUT` if the time is exceeded.
    # @return [Object] the value that was put, or `TIMEOUT`
    def put(value, timeout = nil)
      synchronize do
        wait_for_empty(timeout)

        # If we timed out we won't be empty
        if ns_empty?
          @value = value
          @full_condition.ns_signal
          apply_deref_options(value)
        else
          TIMEOUT
        end
      end
    end

    # Atomically `take`, yield the value to a block for transformation, and then
    # `put` the transformed value. Returns the transformed value. A timeout can
    # be set to limit the time spent blocked, in which case it returns `TIMEOUT`
    # if the time is exceeded.
    # @return [Object] the transformed value, or `TIMEOUT`
    def modify(timeout = nil)
      raise ArgumentError.new('no block given') unless block_given?

      synchronize do
        wait_for_full(timeout)

        # If we timed out we'll still be empty
        if ns_full?
          value = @value
          @value = yield value
          @full_condition.ns_signal
          apply_deref_options(value)
        else
          TIMEOUT
        end
      end
    end

    # Non-blocking version of `take`, that returns `EMPTY` instead of blocking.
    def try_take!
      synchronize do
        if ns_full?
          value = @value
          @value = EMPTY
          @empty_condition.ns_signal
          apply_deref_options(value)
        else
          EMPTY
        end
      end
    end

    # Non-blocking version of `put`, that returns whether or not it was successful.
    def try_put!(value)
      synchronize do
        if ns_empty?
          @value = value
          @full_condition.ns_signal
          true
        else
          false
        end
      end
    end

    # Non-blocking version of `put` that will overwrite an existing value.
    def set!(value)
      synchronize do
        old_value = @value
        @value = value
        @full_condition.ns_signal
        apply_deref_options(old_value)
      end
    end

    # Non-blocking version of `modify` that will yield with `EMPTY` if there is no value yet.
    def modify!
      raise ArgumentError.new('no block given') unless block_given?

      synchronize do
        value = @value
        @value = yield value
        if ns_empty?
          @empty_condition.ns_signal
        else
          @full_condition.ns_signal
        end
        apply_deref_options(value)
      end
    end

    # Returns if the `MVar` is currently empty.
    def empty?
      synchronize { @value == EMPTY }
    end

    # Returns if the `MVar` currently contains a value.
    def full?
      !empty?
    end

    private

    def ns_initialize(value, opts)
      @value = value
      @empty_condition = new_condition
      @full_condition = new_condition
      init_mutex(self)
      set_deref_options(opts)
    end

    def ns_empty?
      @value == EMPTY
    end

    def ns_full?
      ! ns_empty?
    end

    def wait_for_full(timeout)
      wait_while(@full_condition, timeout) { ns_empty? }
    end

    def wait_for_empty(timeout)
      wait_while(@empty_condition, timeout) { ns_full? }
    end

    def wait_while(condition, timeout)
      if timeout.nil?
        while yield
          condition.ns_wait
        end
      else
        stop = Concurrent.monotonic_time + timeout
        while yield && timeout > 0.0
          condition.ns_wait(timeout)
          timeout = stop - Concurrent.monotonic_time
        end
      end
    end
  end
end
