# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require "pathname"

module Jorm
  # Persists request/response traffic to a JSONL file for debugging,
  # redacting sensitive data before writing (see Jorm::Redactor). TeeBody
  # hands it the collected response chunks once a streamed body has
  # finished; Recorder turns those chunks into the on-disk record.
  #
  # Every request/response record is appended to a single dump file as a
  # line of JSON (JSONL). The filename is normally supplied by bin/server
  # (via JO_DUMP_FILE / +file_name+) so that all worker processes for a
  # given server run -- e.g. Falcon's forked workers, which each load
  # config.ru and build their own Recorder -- share one file instead of
  # each creating its own. Writes are flock-protected so concurrent
  # processes/fibers appending at the same time don't interleave lines.
  #
  # Off by default -- opt in with JO_DUMP=1. See Jorm::DbRecorder for the
  # GreptimeDB recorder, which is on by default.
  class Recorder
    attr_reader :file_path

    def initialize(
      enabled: Jorm::Config.record_enabled?,
      dir: Jorm::Config.record_dir,
      file_name: Jorm::Config.record_file
    )
      @enabled = enabled
      @dir = Pathname(dir)

      if @enabled
        ensure_dir!
        file_name ||= "dump-#{Time.now.utc.iso8601(3).tr(":", "-")}.jsonl"
        @file_path = @dir.join(file_name)
        FileUtils.touch(@file_path)
      end
    end

    def enabled?
      @enabled
    end

    def redact_headers(headers)
      Redactor.redact_headers(headers)
    end

    def redact_body_text(text)
      Redactor.redact_body_text(text)
    end

    def parse_body(raw_bytes, content_type)
      Redactor.parse_body(raw_bytes, content_type)
    end

    # Builds and writes the request portion of a record (headers / body /
    # patchedBody) when recording is enabled. +req+'s jorm_request_id ties
    # this record to the response record written later.
    def record_request(req, body_buffer, patched)
      return unless @enabled

      record = {
        "timestamp" => Time.now.utc.iso8601(3),
        "jormRequestId" => req.jorm_request_id,
        "method" => req.method,
        "path_with_query_string" => req.path_with_query_string,
        "upstreamPath" => Jorm::UpstreamClient.upstream_path(req),
        "patched" => patched,
        "request" => {
          "headers" => req.headers,
          "body" => body_buffer,
          "patchedBody" => patched
        }
      }

      write("req", record)
    end

    # Called by TeeBody's on_complete function once a streamed response
    # body has been fully read. Builds a new record for the "response"
    # side from +upstream_result+ (status/headers) and the collected
    # +chunks+ (body), tagged with +req+'s jorm_request_id, then writes
    # it out. Optional +timing+ (started_at / chunk_times / finished_at)
    # is persisted alongside retries/error for debugging.
    def maybe_record_response(req, chunks, upstream_result, timing: nil)
      return unless enabled?

      record = {
        "timestamp" => Time.now.utc.iso8601(3),
        "jormRequestId" => req.jorm_request_id
      }

      begin
        headers = upstream_result.headers.transform_keys(&:to_s).transform_values do |v|
          v.is_a?(Array) ? v.join(", ") : v.to_s
        end
        resp_buf = chunks.join

        response = {
          "status" => upstream_result.status,
          "headers" => redact_headers(headers),
          "body" => resp_buf.empty? ? nil : parse_body(resp_buf, headers["content-type"]),
          "retries" => upstream_result.retries.to_i
        }
        response["error"] = upstream_result.error if upstream_result.error
        if timing
          response["timing"] = {
            "startedAt" => timing[:started_at],
            "chunkTimes" => timing[:chunk_times],
            "finishedAt" => timing[:finished_at]
          }
        end
        record["response"] = response
      rescue StandardError
        # still write what we have
      end

      write("res", record)
    end

    def write(type, record)
      return unless @enabled

      line = "#{JSON.generate(record.merge("type" => type))}\n"

      File.open(@file_path, File::WRONLY | File::APPEND | File::CREAT) do |f|
        f.flock(File::LOCK_EX)
        f.write(line)
      ensure
        f.flock(File::LOCK_UN)
      end

      puts "  \u{1F4C4} recorded #{type} \u2192 #{@file_path}"
    end

    private

    def ensure_dir!
      FileUtils.mkdir_p(@dir) unless @dir.directory?
    end
  end
end
