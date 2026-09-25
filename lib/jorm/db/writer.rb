# frozen_string_literal: true

require "thread"

module Jorm
  module Db
    # Runs blocking `pg` gem calls on a single dedicated background
    # thread, off Falcon/Async's fiber-based reactor thread -- `pg` is a
    # C extension that blocks the whole reactor if called inline from a
    # fiber. `enqueue` hands the writer thread a block to run later;
    # errors inside that block are rescued and logged (never raised back
    # to the request path), so a DB hiccup can't fail/slow down a proxied
    # request.
    #
    # The queue is bounded so a stalled/unreachable DB applies backpressure
    # (drops the oldest recording work) instead of growing unbounded memory
    # under sustained traffic.
    class Writer
      DEFAULT_MAX_QUEUE_SIZE = 1000

      def initialize(max_queue_size: DEFAULT_MAX_QUEUE_SIZE)
        @queue = SizedQueue.new(max_queue_size)
        @thread = Thread.new { run }
        @thread.abort_on_exception = false
      end

      # Schedules +block+ to run on the background thread. Non-blocking
      # unless the queue is full, in which case the oldest job is
      # unblocked (dropped) to make room, so callers never wait on DB I/O.
      def enqueue(&block)
        @queue.push(block, true)
      rescue ThreadError
        drop_oldest_and_retry(&block)
      end

      def close
        @queue.close
        @thread.join(5)
      end

      private

      def drop_oldest_and_retry(&block)
        @queue.pop(true)
        @queue.push(block, true)
      rescue ThreadError, ClosedQueueError
        nil
      end

      def run
        loop do
          job = @queue.pop
          break if job.nil?

          begin
            job.call
          rescue StandardError => e
            warn "Jorm::Db::Writer job error: [#{e.class}] #{e.message}"
          end
        end
      end
    end
  end
end
