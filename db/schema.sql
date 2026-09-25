-- GreptimeDB schema for jorm's request/response recording.
--
-- GreptimeDB is a time-series database: every table needs exactly one
-- TIME INDEX (timestamp) column, and TIME INDEX cannot be changed once a
-- table is created. PRIMARY KEY declares "tag" columns used for storage
-- grouping/ordering -- unlike a relational primary key, it does not
-- enforce uniqueness. Our ids are always freshly generated per write, so
-- that's a non-issue in practice.
--
-- Applied via `bin/migrate` (idempotent thanks to IF NOT EXISTS).
--
-- Column names are all double-quoted because several plain words we'd
-- otherwise use ("id", "method", "status", ...) are reserved keywords
-- in GreptimeDB's SQL parser. Quote them the same way in every
-- INSERT/SELECT that references these tables.

CREATE TABLE IF NOT EXISTS requests (
  "id" STRING,               -- Jorm::Request#jorm_request_id (UUID) -- ties to response_chunks.request_id
  "created_at" TIMESTAMP TIME INDEX DEFAULT CURRENT_TIMESTAMP(),
  "method" STRING,
  "path" STRING,              -- path_with_query_string, e.g. "/v1/messages?beta=true"
  "upstream_path" STRING,
  "patched" BOOLEAN,
  "headers" STRING,           -- redacted request headers, JSON-encoded
  "body" STRING,              -- redacted request body (post-patch)
  PRIMARY KEY ("id")
);

CREATE TABLE IF NOT EXISTS response_chunks (
  "id" STRING,                -- per-chunk UUID, generated at write time
  "request_id" STRING,        -- ties to requests.id (no enforced FK)
  "chunk_index" INT32,         -- 0-based order within the stream
  "created_at" TIMESTAMP TIME INDEX DEFAULT CURRENT_TIMESTAMP(),
  "status" INT16,              -- only set on chunk_index = 0
  "headers" STRING,            -- redacted response headers, JSON-encoded; only set on chunk_index = 0
  "body" STRING,               -- this chunk's raw text (best-effort UTF-8)
  PRIMARY KEY ("request_id", "id")
);
