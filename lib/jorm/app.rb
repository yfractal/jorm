# frozen_string_literal: true

require "json"
require "time"

module Jorm
  class App
    def initialize(
      recorder: CompositeRecorder.new([DbRecorder.new, Recorder.new]),
      upstream: UpstreamClient.new
    )
      @recorder = recorder
      @upstream = upstream
    end

    def call(env)
      req = Jorm::Request.new(env)
      return health_response if req.health_check?

      body, patched = Downstream.new(req).patch

      @recorder.record_request(req, body, patched)

      begin
        result = @upstream.call(
          req: req,
          path: UpstreamClient.upstream_path(req),
          body: body
        )
      rescue UpstreamClient::UpstreamError => e
        return record_and_return_upstream_error(req, e)
      end

      # record response from the upstream
      rack_body = TeeBody.new(result.body) do |chunks, chunk_times|
        @recorder.maybe_record_response(
          req,
          chunks,
          result,
          {
            started_at: req.started_at,
            chunk_times: chunk_times,
            finished_at: Process.clock_gettime(Process::CLOCK_MONOTONIC)
          }
        )
      end

      [result.status, HeaderFilter.copy_response_headers(result.headers), rack_body]
    end

    private

    # Final retryable upstream failure: record a 502 response row (so the
    # failure shows up in the performance report) and return JSON to the
    # client instead of letting Falcon surface a bare 500.
    def record_and_return_upstream_error(req, error)
      result = UpstreamClient::Result.new(
        status: 502,
        headers: { "content-type" => "application/json; charset=utf-8" },
        body: [],
        retries: error.retries,
        error: error.message
      )
      @recorder.maybe_record_response(
        req,
        [],
        result,
        {
          started_at: req.started_at,
          chunk_times: [],
          finished_at: Process.clock_gettime(Process::CLOCK_MONOTONIC)
        }
      )

      [
        502,
        { "content-type" => "application/json; charset=utf-8" },
        [JSON.generate({ "error" => "upstream_error", "message" => error.message })]
      ]
    end

    def health_response
      [
        200,
        { "content-type" => "application/json; charset=utf-8" },
        [JSON.generate({ "ok" => true })]
      ]
    end
  end
end
