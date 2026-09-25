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
  # Bodies are never recorded here, only metadata (method/path/status/
  # headers) -- use the (opt-in) file recorder for full bodies.
  #
  # Each requests row has its own "id" (UUID generated here -- GreptimeDB
  # has no SERIAL/IDENTITY) plus "jorm_request_id" (from the Request),
  # which the responses row shares.
  class DbRecorder
    INSERT_REQUEST_SQL = <<~SQL.freeze
      INSERT INTO requests
        ("id", "jorm_request_id", "method", "path", "upstream_path", "patched", "headers")
      VALUES ($1, $2, $3, $4, $5, $6, $7)
    SQL

    INSERT_RESPONSE_SQL = <<~SQL.freeze
      INSERT INTO responses
        ("id", "jorm_request_id", "status", "headers")
      VALUES ($1, $2, $3, $4)
    SQL

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

    def record_request(req, _body_buffer, patched)
      return unless enabled?

      id = SecureRandom.uuid
      jorm_request_id = req.jorm_request_id
      method = req.method
      path = req.path_with_query_string
      upstream_path = Jorm::UpstreamClient.upstream_path(req)
      headers = JSON.generate(Redactor.redact_headers(req.headers))

      @writer.enqueue do
        @connection.exec_params(
          INSERT_REQUEST_SQL,
          [id, jorm_request_id, method, path, upstream_path, patched, headers]
        )
      end
    end

    def maybe_record_response(req, _chunks, upstream_result)
      return unless enabled?

      id = SecureRandom.uuid
      jorm_request_id = req.jorm_request_id
      status = upstream_result.status

      headers = upstream_result.headers.transform_keys(&:to_s).transform_values do |v|
        v.is_a?(Array) ? v.join(", ") : v.to_s
      end
      redacted_headers = JSON.generate(Redactor.redact_headers(headers))

      @writer.enqueue do
        @connection.exec_params(
          INSERT_RESPONSE_SQL,
          [id, jorm_request_id, status, redacted_headers]
        )
      end
    end
  end
end
