# frozen_string_literal: true

require "json"
require "time"

module DsProxy
  class App
    def initialize(
      dump_store: DumpStore.new,
      upstream: UpstreamClient.new
    )
      @dump_store = dump_store
      @upstream = upstream
    end

    def call(env)
      req = Request.new(env)
      return health_response if req.health_check?

      body_buffer, patched = patch_json_body(req.body, req.content_type)
      upstream_path = "#{Config::UPSTREAM_PREFIX}#{req.url.empty? ? "/" : req.url}"

      dump_meta = build_dump_meta(req, upstream_path, patched)
      record_request_dump(dump_meta, req.body, body_buffer, req.content_type, patched)

      upstream_headers = HeaderFilter.copy_request_headers(
        req.headers,
        body_buffer.bytesize
      )

      result, error_response = call_upstream(req, upstream_path, upstream_headers, body_buffer)
      return error_response if error_response

      status = result.status || 502
      log_request(req, patched, status)

      response_headers = HeaderFilter.copy_response_headers(result.headers)
      body = attach_response_dump(dump_meta, result, status, response_headers)

      [status, response_headers, body]
    end

    private

    # Patches the request body in-place when it matches the security
    # classifier, returning the (possibly rewritten) body and whether it
    # was patched.
    def patch_json_body(body_buffer, content_type)
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

    def build_dump_meta(req, upstream_path, patched)
      {
        "timestamp" => Time.now.utc.iso8601(3),
        "method" => req.method,
        "url" => req.url,
        "upstreamPath" => upstream_path,
        "patched" => patched,
        "request" => {
          "headers" => @dump_store.redact_headers(req.headers),
          "body" => nil
        },
        "response" => nil
      }
    end

    # Fills in the request portion of dump_meta (body / patchedBody) when
    # dumping is enabled.
    def record_request_dump(dump_meta, original_body, body_buffer, content_type, patched)
      return unless @dump_store.enabled?

      begin
        if !original_body.empty?
          dump_meta["request"]["body"] =
            @dump_store.parse_body_for_dump(original_body, content_type)
        end

        if patched
          dump_meta["request"]["patchedBody"] =
            @dump_store.parse_body_for_dump(body_buffer, content_type)
        end
      rescue StandardError
        # ignore parse failures in dump
      end
    end

    # Proxies the request to upstream. Returns [result, nil] on success or
    # [nil, rack_error_response] if the upstream call raised.
    def call_upstream(req, upstream_path, upstream_headers, body_buffer)
      result = @upstream.call(
        method: req.method,
        path: upstream_path,
        headers: upstream_headers,
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

    def log_request(req, patched, status)
      tag = patched ? "[classifier patched]" : "[pass]"
      puts "#{Time.now.utc.iso8601} #{req.method} #{req.url} #{tag} -> #{status}"
    end

    # Attaches response dumping to the response body when dumping is
    # enabled, writing the dump record either immediately (request-only
    # dumps) or once the response body has been fully streamed.
    def attach_response_dump(dump_meta, result, status, response_headers)
      body = result.body
      return body unless @dump_store.enabled?

      unless @dump_store.dump_response?
        @dump_store.write("req", dump_meta)
        return body
      end

      dump_meta["response"] = {
        "status" => status,
        "headers" => @dump_store.redact_headers(
          result.headers.transform_keys(&:to_s).transform_values do |v|
            v.is_a?(Array) ? v.join(", ") : v.to_s
          end
        ),
        "body" => nil
      }

      resp_ct = response_headers["content-type"].to_s
      TeeBody.new(body) do |chunks|
        begin
          resp_buf = chunks.join
          if !resp_buf.empty?
            dump_meta["response"]["body"] =
              @dump_store.parse_body_for_dump(resp_buf, resp_ct)
          end
        rescue StandardError
          # still dump what we have
        ensure
          @dump_store.write("res", dump_meta)
        end
      end
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
