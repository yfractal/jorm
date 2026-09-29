# frozen_string_literal: true

require "json"
require "securerandom"

module Jorm
  # Persists request/response traffic to GreptimeDB (see
  # docker-compose.yml + db/schema.sql), redacting sensitive data first
  # (see Jorm::Redactor). Same public interface as Jorm::Recorder so both
  # can be used interchangeably or fanned out to via CompositeRecorder.
  #
  # On by default -- opt out with JO_DB_RECORD=0. All actual DB I/O runs
  # on Db::Writer's background thread, so a slow/unavailable DB can't
  # stall a proxied request.
  #
  # One row is written to "requests" per request and one row to
  # "responses" per response -- unlike response_chunks in earlier
  # versions of this schema, the response is recorded once, after
  # TeeBody has collected the full stream (see Jorm::App), mirroring how
  # Jorm::Recorder writes a single "res" record to the dump file.
  #
  # Each requests row has its own "id" (UUID generated here -- GreptimeDB
  # has no SERIAL/IDENTITY) plus "jorm_request_id" (from the Request),
  # which the responses row shares.
  #
  # Timing / retry / error columns (ttft_ms, duration_ms, retry_count,
  # error) are derived from the +timing+ keyword and the upstream Result
  # so the performance report page can query them without joining.
  class DbRecorder
    INSERT_REQUEST_SQL = <<~SQL.freeze
      INSERT INTO requests
        ("id", "jorm_request_id", "method", "path", "upstream_path", "patched", "headers", "body", "patched_body")
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
    SQL

    INSERT_RESPONSE_SQL = <<~SQL.freeze
      INSERT INTO responses
        ("id", "jorm_request_id", "status", "headers", "body",
         "ttft_ms", "duration_ms", "retry_count", "error")
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
    SQL

    # Marker substring present in Anthropic-compatible SSE chunks that
    # carry the first generated token (text or thinking).
    FIRST_TOKEN_MARKER = "content_block_delta"

    def initialize(
      enabled: Jorm::Config.db_record_enabled?,
      connection: enabled ? Db::Connection.new : nil,
      writer: enabled ? Db::Writer.new : nil
    )
      @enabled = enabled
      @connection = connection
      @writer = writer
    end

    def enabled?
      @enabled
    end

    # +body_buffer+ is the (possibly patched) body Jorm::App is about to
    # forward upstream; +req.body+ (memoized on the Request, unaffected
    # by Downstream's patching) is the original body as received. Both
    # are recorded, redacted, so patched and unpatched traffic can be
    # diffed later -- they're identical strings when +patched+ is false.
    def record_request(req, body_buffer, patched)
      return unless enabled?

      id = SecureRandom.uuid
      jorm_request_id = req.jorm_request_id
      method = req.method
      path = req.path_with_query_string
      upstream_path = Jorm::UpstreamClient.upstream_path(req)
      headers = JSON.generate(Redactor.redact_headers(req.headers))
      body = Redactor.redact_body_text(req.body.to_s)
      patched_body = Redactor.redact_body_text(body_buffer.to_s)

      @writer.enqueue do
        @connection.exec_params(
          INSERT_REQUEST_SQL,
          [id, jorm_request_id, method, path, upstream_path, patched, headers, body, patched_body]
        )
      end
    end

    # Mirrors how Jorm::Recorder builds its "res" record's body: parsed
    # (and re-serialized, since "body" is a STRING column) when the
    # content-type says JSON, left as redacted raw text otherwise, and
    # nil for an empty body -- rather than always storing raw chunk text.
    #
    # +timing+ is a hash with :started_at / :chunk_times / :finished_at
    # (monotonic floats). Optional so older call sites and tests keep
    # working; missing timing leaves the timing columns NULL.
    def maybe_record_response(req, chunks, upstream_result, timing: nil)
      return unless enabled?

      id = SecureRandom.uuid
      jorm_request_id = req.jorm_request_id
      status = upstream_result.status
      retry_count = upstream_result.retries.to_i

      headers = upstream_result.headers.transform_keys(&:to_s).transform_values do |v|
        v.is_a?(Array) ? v.join(", ") : v.to_s
      end
      redacted_headers = JSON.generate(Redactor.redact_headers(headers))
      raw_body = chunks.join.dup.force_encoding("UTF-8").scrub
      parsed_body = Redactor.parse_body(raw_body, headers["content-type"])
      body = parsed_body.is_a?(String) ? parsed_body : JSON.generate(parsed_body) unless parsed_body.nil?

      error = derive_error(
        status: status,
        result_error: upstream_result.error,
        parsed_body: parsed_body,
        raw_body: raw_body
      )
      duration_ms = derive_duration_ms(timing)
      ttft_ms = derive_ttft_ms(
        timing: timing,
        duration_ms: duration_ms,
        status: status,
        error: error,
        content_type: headers["content-type"],
        chunks: chunks
      )

      @writer.enqueue do
        @connection.exec_params(
          INSERT_RESPONSE_SQL,
          [id, jorm_request_id, status, redacted_headers, body,
           ttft_ms, duration_ms, retry_count, error]
        )
      end
    end

    private

    def derive_duration_ms(timing)
      return nil unless timing

      started = timing[:started_at]
      finished = timing[:finished_at]
      return nil unless started && finished

      ((finished - started) * 1000.0).round(3)
    end

    # Time-to-first-token: for streaming responses, ms until the first
    # chunk that contains a content_block_delta (text or thinking). For
    # a successful non-streaming JSON response, equals duration_ms. NULL
    # when the response is an error or when timing is unavailable.
    def derive_ttft_ms(timing:, duration_ms:, status:, error:, content_type:, chunks:)
      return nil if error || status.to_i >= 400
      return nil unless timing && timing[:started_at]

      started = timing[:started_at]
      content_type = content_type.to_s

      if content_type.include?("text/event-stream")
        chunk_times = timing[:chunk_times] || []
        chunks.each_with_index do |chunk, i|
          next unless chunk.to_s.include?(FIRST_TOKEN_MARKER)
          next unless chunk_times[i]

          return ((chunk_times[i] - started) * 1000.0).round(3)
        end
        nil
      else
        duration_ms
      end
    end

    # Prefer the explicit Result#error (transport failure), then a JSON
    # body's error.message, then an SSE mid-stream error event, then a
    # generic http_<status> for 4xx/5xx responses with no message.
    def derive_error(status:, result_error:, parsed_body:, raw_body:)
      return result_error if result_error && !result_error.to_s.empty?

      message = error_message_from_body(parsed_body)
      return message if message

      sse_message = sse_error_message(raw_body)
      return sse_message if sse_message

      return "http_#{status}" if status.to_i >= 400

      nil
    end

    def error_message_from_body(parsed_body)
      return nil unless parsed_body.is_a?(Hash)

      err = parsed_body["error"]
      case err
      when Hash
        err["message"] || err["type"] || err.to_s
      when String
        err
      end
    end

    def sse_error_message(raw_body)
      return nil unless raw_body.to_s.include?("event: error")

      Redactor.sse_events(raw_body).each do |event|
        next unless event["event"] == "error"

        data = event["data"]
        next unless data.is_a?(Hash)

        err = data["error"]
        case err
        when Hash
          return err["message"] || err["type"] || err.to_s
        when String
          return err
        else
          return data["message"] || "sse_error"
        end
      end

      "sse_error"
    end
  end
end
