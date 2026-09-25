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
  # One row is written to "requests" per request, and one row per
  # streamed response chunk (as collected by TeeBody) to
  # "response_chunks" -- status/headers are only stored on the chunk_index
  # = 0 row, since GreptimeDB has no notion of a single parent row you
  # could update later once headers become known.
  #
  # Each requests row has its own "id" (UUID generated here -- GreptimeDB
  # has no SERIAL/IDENTITY) plus "jorm_request_id" (from the Request),
  # which response_chunks join on.
  class DbRecorder
    INSERT_REQUEST_SQL = <<~SQL.freeze
      INSERT INTO requests
        ("id", "jorm_request_id", "method", "path", "upstream_path", "patched", "headers", "body")
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    SQL

    INSERT_RESPONSE_CHUNK_SQL = <<~SQL.freeze
      INSERT INTO response_chunks
        ("id", "jorm_request_id", "chunk_index", "status", "headers", "body")
      VALUES ($1, $2, $3, $4, $5, $6)
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

    def record_request(req, body_buffer, patched)
      return unless enabled?

      id = SecureRandom.uuid
      jorm_request_id = req.jorm_request_id
      method = req.method
      path = req.path_with_query_string
      upstream_path = Jorm::UpstreamClient.upstream_path(req)
      headers = JSON.generate(Redactor.redact_headers(req.headers))
      body = Redactor.redact_body_text(body_buffer.to_s)

      @writer.enqueue do
        @connection.exec_params(
          INSERT_REQUEST_SQL,
          [id, jorm_request_id, method, path, upstream_path, patched, headers, body]
        )
      end
    end

    def maybe_record_response(req, chunks, upstream_result)
      return unless enabled?

      jorm_request_id = req.jorm_request_id

      headers = upstream_result.headers.transform_keys(&:to_s).transform_values do |v|
        v.is_a?(Array) ? v.join(", ") : v.to_s
      end
      redacted_headers = JSON.generate(Redactor.redact_headers(headers))
      status = upstream_result.status

      chunks.each_with_index do |chunk, index|
        id = SecureRandom.uuid
        body = Redactor.redact_body_text(chunk.to_s.dup.force_encoding("UTF-8").scrub)
        chunk_status = index.zero? ? status : nil
        chunk_headers = index.zero? ? redacted_headers : nil

        @writer.enqueue do
          @connection.exec_params(
            INSERT_RESPONSE_CHUNK_SQL,
            [id, jorm_request_id, index, chunk_status, chunk_headers, body]
          )
        end
      end
    end
  end
end
