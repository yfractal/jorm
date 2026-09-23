# frozen_string_literal: true

module Jorm
  # Rack body wrapper that streams chunks to the client while also
  # collecting them for dump capture, then fires +on_complete+.
  class TeeBody
    def initialize(source, &on_complete)
      @source = source
      @on_complete = on_complete
      @chunks = []
      @closed = false
    end

    def each
      return enum_for(__method__) unless block_given?

      @source.each do |chunk|
        @chunks << chunk.dup
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
      @on_complete&.call(@chunks)
    rescue StandardError
      # Dump failures must not break the client response.
    end
  end
end
