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
      path = env["PATH_INFO"].to_s
      return health_response if path == "/health"

      request_headers = HeaderFilter.from_rack_env(env)
      original_body = read_body(env)
      body_buffer = original_body
      patched = false
      content_type = request_headers["content-type"].to_s

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

      query = env["QUERY_STRING"]
      request_url = path
      request_url = "#{path}?#{query}" unless query.to_s.empty?
      upstream_path = "#{Config::UPSTREAM_PREFIX}#{request_url.empty? ? "/" : request_url}"

      dump_meta = {
        "timestamp" => Time.now.utc.iso8601(3),
        "method" => env["REQUEST_METHOD"],
        "url" => request_url,
        "upstreamPath" => upstream_path,
        "patched" => patched,
        "request" => {
          "headers" => @dump_store.redact_headers(request_headers),
          "body" => nil
        },
        "response" => nil
      }

      if @dump_store.enabled?
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

      upstream_headers = HeaderFilter.copy_request_headers(
        request_headers,
        body_buffer.bytesize
      )

      begin
        result = @upstream.call(
          method: env["REQUEST_METHOD"],
          path: upstream_path,
          headers: upstream_headers,
          body: body_buffer.empty? ? nil : body_buffer
        )
      rescue StandardError => e
        warn "Upstream error: [#{e.class}] #{e.message || "(no message)"}"
        return [
          502,
          { "content-type" => "application/json; charset=utf-8" },
          [JSON.generate({ "error" => "upstream_error", "message" => e.message })]
        ]
      end

      status = result.status || 502
      tag = patched ? "[classifier patched]" : "[pass]"
      puts "#{Time.now.utc.iso8601} #{env["REQUEST_METHOD"]} #{request_url} #{tag} -> #{status}"

      response_headers = HeaderFilter.copy_response_headers(result.headers)
      body = result.body

      if @dump_store.enabled? && @dump_store.dump_response?
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
        body = TeeBody.new(body) do |chunks|
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
      elsif @dump_store.enabled?
        @dump_store.write("req", dump_meta)
      end

      [status, response_headers, body]
    end

    private

    def health_response
      [
        200,
        { "content-type" => "application/json; charset=utf-8" },
        [JSON.generate({ "ok" => true })]
      ]
    end

    def read_body(env)
      input = env["rack.input"]
      return "" unless input

      input.read.to_s
    ensure
      input.rewind if input.respond_to?(:rewind)
    end
  end
end
