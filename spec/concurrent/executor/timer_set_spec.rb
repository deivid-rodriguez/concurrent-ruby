require 'timecop'

module Concurrent

  describe TimerSet do

    let(:executor){ Concurrent::SingleThreadExecutor.new }
    subject{ TimerSet.new(executor: executor) }

    after(:each){ subject.kill }

    context 'construction' do

      before(:all) do
        reset_gem_configuration
      end

      after(:each) do
        reset_gem_configuration
      end

      it 'uses the executor given at construction' do
        executor = Concurrent.global_immediate_executor
        expect(executor).to receive(:post).with(no_args)
        subject = TimerSet.new(executor: executor)
        subject.post(0){ nil }
      end

      it 'uses the global io executor be default' do
        latch = Concurrent::CountDownLatch.new(1)
        expect(Concurrent.global_io_executor).to receive(:post).with(no_args)
        subject = TimerSet.new
        subject.post(0){ latch.count_down }
        latch.wait(0.1)
      end
    end

    context '#post' do

      it 'raises an exception when given a task with a delay less than zero' do
        expect {
          subject.post(-10){ nil }
        }.to raise_error(ArgumentError)
      end

      it 'raises an exception when no block given' do
        expect {
          subject.post(10)
        }.to raise_error(ArgumentError)
      end

      it 'immediately posts a task when the delay is zero' do
        timer = subject.instance_variable_get(:@timer_executor)
        expect(timer).not_to receive(:post).with(any_args)
        subject.post(0){ true }
      end
    end

    context 'execution' do

      it 'executes a given task when given an interval in seconds' do
        latch = CountDownLatch.new(1)
        subject.post(0.1){ latch.count_down }
        expect(latch.wait(0.2)).to be_truthy
      end

      it 'returns an IVar when posting a task' do
        expect(subject.post(0.1) { nil }).to be_a Concurrent::IVar
      end

      it 'executes a given task when given an interval in seconds, even if longer tasks have been scheduled' do
        latch = CountDownLatch.new(1)
        subject.post(0.5){ nil }
        subject.post(0.1){ latch.count_down }
        expect(latch.wait(0.2)).to be_truthy
      end

      it 'passes all arguments to the task on execution' do
        expected = nil
        latch = CountDownLatch.new(1)
        subject.post(0.1, 1, 2, 3) do |*args|
          expected = args
          latch.count_down
        end
        expect(latch.wait(0.2)).to be_truthy
        expect(expected).to eq [1, 2, 3]
      end

      it 'does not execute tasks early' do
        latch = Concurrent::CountDownLatch.new(1)
        start = Time.now.to_f
        subject.post(0.2){ latch.count_down }
        expect(latch.wait(1)).to be true
        expect(Time.now.to_f - start).to be >= 0.19
      end

      it 'executes all tasks scheduled for the same time' do
        latch = CountDownLatch.new(5)
        5.times{ subject.post(0.1){ latch.count_down } }
        expect(latch.wait(0.2)).to be_truthy
      end

      it 'executes tasks with different times in schedule order' do
        latch = CountDownLatch.new(3)
        expected = []
        3.times{|i| subject.post(i/10){ expected << i; latch.count_down } }
        latch.wait(1)
        expect(expected).to eq [0, 1, 2]
      end

      it 'executes tasks with different times in schedule time' do
        tests = 3
        interval = 0.1
        latch = CountDownLatch.new(tests)
        expected = Queue.new
        start = Time.now

        (1..tests).each do |i|
          subject.post(interval * i) { expected << Time.now - start; latch.count_down }
        end

        expect(latch.wait((tests * interval) + 1)).to be true

        (1..tests).each do |i|
          delta = expected.pop
          expect(delta).to be_within(0.1).of((i * interval) + 0.05)
        end
      end

      it 'continues to execute new tasks even after the queue is emptied' do
        3.times do |i|
          task = subject.post(0.1){ i }
          expect(task.value).to eq i
        end
      end
    end

    context 'resolution' do

      it 'sets the IVar value on success when delay is zero' do
        job = subject.post(0){ 42 }
        expect(job.value).to eq 42
        expect(job.reason).to be_nil
        expect(job).to be_fulfilled
      end

      it 'sets the IVar value on success when given a delay' do
        job = subject.post(0.1){ 42 }
        expect(job.value).to eq 42
        expect(job.reason).to be_nil
        expect(job).to be_fulfilled
      end

      it 'sets the IVar reason on failure when delay is zero' do
        error = ArgumentError.new('expected error')
        job = subject.post(0){ raise error }
        expect(job.value).to be_nil
        expect(job.reason).to eq error
        expect(job).to be_rejected
      end

      it 'sets the IVar reason on failure when given a delay' do
        error = ArgumentError.new('expected error')
        job = subject.post(0.1){ raise error }
        expect(job.value).to be_nil
        expect(job.reason).to eq error
        expect(job).to be_rejected
      end
    end

    context 'task cancellation' do

      after(:each) do
        Timecop.return
      end

      it 'fails to cancel the task once processing has begun' do
        start_latch = Concurrent::CountDownLatch.new
        continue_latch = Concurrent::CountDownLatch.new
        job = subject.post(0.1) do
          start_latch.count_down
          continue_latch.wait(2)
          42
        end

        start_latch.wait(2)
        success = job.cancel
        continue_latch.count_down

        expect(success).to be false
        expect(job.value).to eq 42
        expect(job.reason).to be_nil
      end

      it 'fails to cancel the task once processing is complete' do
        job = subject.post(0.1){ 42 }

        job.wait(2)
        success = job.cancel

        expect(success).to be false
        expect(job.value).to eq 42
        expect(job.reason).to be_nil
      end

      it 'cancels a pending task' do
        actual = AtomicBoolean.new(false)
        Timecop.freeze
        job = subject.post(0.1){ actual.make_true }
        success = job.cancel
        Timecop.travel(1)
        expect(success).to be true
        expect(job.value(0)).to be_nil
        expect(job.reason).to be_a CancelledOperationError
      end

      it 'returns false when not running' do
        task = subject.post(10){ nil }
        subject.shutdown
        subject.wait_for_termination(1)
        expect(task.cancel).to be false
      end
    end

    context 'task rescheduling' do

      let(:queue) { subject.instance_variable_get(:@queue) }

      it 'raises an exception when given an invalid time' do
        task = subject.post(10){ nil }
        expect{ task.reschedule(-1) }.to raise_error(ArgumentError)
      end

      it 'does not change the current schedule when given an invalid time' do
        task = subject.post(10){ nil }
        expected = task.schedule_time
        begin
          task.reschedule(-1)
        rescue
        end
        expect(task.schedule_time).to eq expected
      end

      it 'reschdules a pending and unpost task when given a valid time' do
        initial_delay = 10
        rescheduled_delay = 20
        task = subject.post(initial_delay){ nil }
        original_schedule = task.schedule_time
        success = task.reschedule(rescheduled_delay)
        expect(success).to be true
        expect(task.initial_delay).to be_within(0.01).of(rescheduled_delay)
        expect(task.schedule_time).to be > original_schedule
      end

      it 'returns false once the task has been post to the executor' do
        start_latch = Concurrent::CountDownLatch.new
        continue_latch = Concurrent::CountDownLatch.new

        task = subject.post(0.1) do
          start_latch.count_down
          continue_latch.wait(2)
        end
        start_latch.wait(2)

        expected = task.schedule_time
        success = task.reschedule(10)
        continue_latch.count_down
        expect(success).to be false
        expect(task.schedule_time).to eq expected
      end

      it 'returns false once the task is processing' do
        start_latch = Concurrent::CountDownLatch.new
        continue_latch = Concurrent::CountDownLatch.new
        task = subject.post(0.1) do
          start_latch.count_down
          continue_latch.wait(2)
        end
        start_latch.wait(2)

        expected = task.schedule_time
        success = task.reschedule(10)
        continue_latch.count_down
        expect(success).to be false
        expect(task.schedule_time).to eq expected
      end

      it 'returns false once the task has is complete' do
        task = subject.post(0.1){ nil }
        task.value(2)
        expected = task.schedule_time
        success = task.reschedule(10)
        expect(success).to be false
        expect(task.schedule_time).to eq expected
      end

      it 'returns false when not running' do
        task = subject.post(10){ nil }
        subject.shutdown
        subject.wait_for_termination(1)
        expected = task.schedule_time
        success = task.reschedule(10)
        expect(success).to be false
        expect(task.schedule_time).to be_within(0.01).of(expected)
      end
    end

    context 'task resetting' do

      it 'calls #reschedule with the original delay' do
        initial_delay = 10
        task = subject.post(initial_delay){ nil }
        expect(task).to receive(:ns_reschedule).with(initial_delay)
        task.reset
      end
    end

    context 'termination' do

      it 'cancels all pending tasks on #shutdown' do
        count = 10
        latch = Concurrent::CountDownLatch.new(count)
        expected = AtomicFixnum.new(0)

        count.times do |i|
          subject.post(0.2){ expected.increment }
          latch.count_down
        end

        latch.wait(1)
        subject.shutdown
        subject.wait_for_termination(1)

        expect(expected.value).to eq 0
      end

      it 'cancels all pending tasks on #kill' do
        count = 10
        latch = Concurrent::CountDownLatch.new(count)
        expected = AtomicFixnum.new(0)

        count.times do |i|
          subject.post(0.2){ expected.increment }
          latch.count_down
        end

        latch.wait(1)
        subject.kill
        subject.wait_for_termination(1)

        expect(expected.value).to eq 0
      end

      it 'stops the monitor thread on #shutdown' do
        timer_executor = subject.instance_variable_get(:@timer_executor)
        subject.shutdown
        subject.wait_for_termination(1)
        expect(timer_executor).not_to be_running
      end

      it 'kills the monitor thread on #kill' do
        timer_executor = subject.instance_variable_get(:@timer_executor)
        subject.kill
        subject.wait_for_termination(1)
        expect(timer_executor).not_to be_running
      end

      it 'rejects tasks once shutdown' do
        latch = Concurrent::CountDownLatch.new(1)
        expected = AtomicFixnum.new(0)

        subject.shutdown
        subject.wait_for_termination(1)

        expect(subject.post(0){ expected.increment; latch.count_down }).to be_falsey
        latch.wait(0.1)
        expect(expected.value).to eq 0
      end

      it 'rejects tasks once killed' do
        latch = Concurrent::CountDownLatch.new(1)
        expected = AtomicFixnum.new(0)

        subject.kill
        subject.wait_for_termination(1)

        expect(subject.post(0){ expected.increment; latch.count_down }).to be_falsey
        latch.wait(0.1)
        expect(expected.value).to eq 0
      end

      specify '#wait_for_termination returns true if shutdown completes before timeout' do
        latch = Concurrent::CountDownLatch.new(1)
        subject.post(0){ latch.count_down }
        latch.wait(1)
        subject.shutdown
        expect(subject.wait_for_termination(0.1)).to be_truthy
      end

      specify '#wait_for_termination returns false on timeout' do
        latch = Concurrent::CountDownLatch.new(1)
        subject.post(0){ latch.count_down }
        latch.wait(0.1)
        # do not call shutdown -- force timeout
        expect(subject.wait_for_termination(0.1)).to be_falsey
      end
    end

    context 'state' do

      it 'is running? when first created' do
        expect(subject).to be_running
        expect(subject).not_to be_shutdown
      end

      it 'is running? after tasks have been post' do
        subject.post(0.1){ nil }
        expect(subject).to be_running
        expect(subject).not_to be_shutdown
      end

      it 'is shutdown? after shutdown completes' do
        subject.shutdown
        subject.wait_for_termination(1)
        expect(subject).not_to be_running
        expect(subject).to be_shutdown
      end

      it 'is shutdown? after being killed' do
        subject.kill
        subject.wait_for_termination(1)
        expect(subject).not_to be_running
        expect(subject).to be_shutdown
      end
    end
  end
end
