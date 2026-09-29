# frozen_string_literal: true

module Jorm
  # Rack body wrapper that streams chunks to the client while also
  # collecting them for dump capture, then fires +on_complete+.
  #
  # +on_complete+ is called as +call(chunks, chunk_times)+ where
  # +chunk_times+ are monotonic clock readings taken as each chunk
  # arrived (used for TTFT). Existing one-argument blocks still work --
  # Ruby ignores the extra argument.
  class TeeBody
    def initialize(source, &on_complete)
      @source = source
      @on_complete = on_complete
      @chunks = []
      @chunk_times = []
      @closed = false
    end

    def each
      return enum_for(__method__) unless block_given?

      @source.each do |chunk|
        @chunks << chunk.dup
        @chunk_times << Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield chunk
      end
    ensure
      finish!
    end

    def close
      @source.close if @source.respond_to?(:close)
    ensure
      finish!
    end

    private

    def finish!
      return if @closed

      @closed = true
      @on_complete&.call(@chunks, @chunk_times)
    rescue StandardError
      # Dump failures must not break the client response.
    end
  end
end
