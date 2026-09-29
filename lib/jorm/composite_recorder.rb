# frozen_string_literal: true

module Jorm
  # Fans record_request/maybe_record_response out to multiple recorders
  # (e.g. DbRecorder + Recorder), isolating each one's failures so one
  # recorder misbehaving can't stop another from running or break the
  # proxied request.
  class CompositeRecorder
    def initialize(recorders)
      @recorders = recorders
    end

    def record_request(req, body_buffer, patched)
      each_recorder { |r| r.record_request(req, body_buffer, patched) }
    end

    def maybe_record_response(req, chunks, upstream_result, timing)
      each_recorder { |r| r.maybe_record_response(req, chunks, upstream_result, timing) }
    end

    private

    def each_recorder
      @recorders.each do |recorder|
        yield recorder
      rescue StandardError => e
        warn "Jorm::CompositeRecorder: #{recorder.class} failed: [#{e.class}] #{e.message}"
      end
    end
  end
end
