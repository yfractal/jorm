# frozen_string_literal: true

require "json"
require "time"

module DsProxy
  class App
    def initialize(
      recorder: Recorder.new,
      upstream: UpstreamClient.new
    )
      @recorder = recorder
      @upstream = upstream
    end

    def call(env)
      req = Rack::Request.new(env)
      return health_response if req.health_check?

      body, patched = Downstream.new(req).patch

      record = @recorder.build_record(req, patched)
      @recorder.record_request(record, req.body, body, req.content_type, patched)

      result = @upstream.call(
        req: req,
        path: UpstreamClient.upstream_path(req),
        body: body
      )

      # record response from the upstream
      body = TeeBody.new(result.body) { |chunks| @recorder.maybe_record_response(record, chunks, result) }

      [result.status, HeaderFilter.copy_response_headers(result.headers), body]
    end

    private

    # Proxies the request to upstream. Returns [result, nil] on success or
    # [nil, rack_error_response] if the upstream call raised.
    def call_upstream(req, upstream_path, body_buffer)
      result = @upstream.call(
        req: req,
        path: upstream_path,
        body: body_buffer.empty? ? nil : body_buffer
      )
      [result, nil]
    rescue StandardError => e
      warn "Upstream error: [#{e.class}] #{e.message || "(no message)"}"
      error_response = [
        502,
        { "content-type" => "application/json; charset=utf-8" },
        [JSON.generate({ "error" => "upstream_error", "message" => e.message })]
      ]
      [nil, error_response]
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
