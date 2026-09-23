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
      req = Request.new(env)
      return health_response if req.health_check?

      body, patched = patch_request(req)
      upstream_path = "#{Config::UPSTREAM_PREFIX}#{req.url.empty? ? "/" : req.url}"

      record = build_record(req, upstream_path, patched)
      record_request(record, req.body, body, req.content_type, patched)

      result = @upstream.call(
        req: req,
        path: upstream_path,
        body: body
      )

      # record response from the upstream
      body = TeeBody.new(result.body) { |chunks| @recorder.maybe_record_response(record, chunks, result) }

      [result.status, HeaderFilter.copy_response_headers(result.headers), body]
    end

    private

    # Patches the request body in-place when it matches the security
    # classifier, returning the (possibly rewritten) body and whether it
    # was patched.
    def patch_request(req)
      body_buffer = req.body
      content_type = req.content_type

      patched = false

      if !body_buffer.empty? && content_type.include?("application/json")
        begin
          parsed = JSON.parse(body_buffer)
          if SecurityClassifier.match?(parsed)
            SecurityClassifier.patch!(parsed)
            body_buffer = JSON.generate(parsed)
            patched = true
          end
        rescue JSON::ParserError
          # keep original request on parse failure
        end
      end

      [body_buffer, patched]
    end

    def build_record(req, upstream_path, patched)
      {
        "timestamp" => Time.now.utc.iso8601(3),
        "method" => req.method,
        "url" => req.url,
        "upstreamPath" => upstream_path,
        "patched" => patched,
        "request" => {
          "headers" => @recorder.redact_headers(req.headers),
          "body" => nil
        },
        "response" => nil
      }
    end

    # Fills in the request portion of +record+ (body / patchedBody) when
    # recording is enabled.
    def record_request(record, original_body, body_buffer, content_type, patched)
      return unless @recorder.enabled?

      begin
        if !original_body.empty?
          record["request"]["body"] =
            @recorder.parse_body(original_body, content_type)
        end

        if patched
          record["request"]["patchedBody"] =
            @recorder.parse_body(body_buffer, content_type)
        end
      rescue StandardError
        # ignore parse failures when recording
      end
    end

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
