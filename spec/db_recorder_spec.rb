# frozen_string_literal: true

require "stringio"
require_relative "spec_helper"

RSpec.describe Jorm::DbRecorder do
  # Runs enqueued jobs synchronously, inline -- no real thread/DB needed.
  class InlineWriter
    def enqueue(&block)
      block.call
    end
  end

  let(:connection) { instance_double(Jorm::Db::Connection) }
  let(:writer) { InlineWriter.new }

  subject(:recorder) { described_class.new(enabled: true, connection: connection, writer: writer) }

  def build_req(overrides = {})
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/v1/messages",
      "QUERY_STRING" => "",
      "rack.input" => StringIO.new(""),
      "CONTENT_TYPE" => "application/json"
    }.merge(overrides)
    Jorm::Request.new(env)
  end

  describe "#record_request" do
    it "inserts a redacted row into requests, with both the original and patched body" do
      req = build_req(
        "HTTP_AUTHORIZATION" => "Bearer sk-secret",
        "rack.input" => StringIO.new('{"key":"sk-abcdefghijk","thinking":true}')
      )

      expect(connection).to receive(:exec_params) do |sql, params|
        expect(sql).to include("INSERT INTO requests")
        id, jorm_request_id, method, path, upstream_path, patched, headers, body, patched_body = params
        expect(id).to match(/\A[0-9a-f-]{36}\z/)
        expect(id).not_to eq(req.jorm_request_id)
        expect(jorm_request_id).to eq(req.jorm_request_id)
        expect(method).to eq("POST")
        expect(path).to eq("/v1/messages")
        expect(upstream_path).to eq(Jorm::UpstreamClient.upstream_path(req))
        expect(patched).to eq(true)
        expect(headers).to include("***redacted***")
        expect(body).to eq('{"key":"sk-***redacted***","thinking":true}')
        expect(patched_body).to eq('{"key":"sk-***redacted***"}')
      end

      recorder.record_request(req, '{"key":"sk-abcdefghijk"}', true)
    end
  end

  describe "#maybe_record_response" do
    def capture_response_params(req, chunks, upstream_result, timing: nil)
      timing ||= { started_at: nil, chunk_times: [], finished_at: nil }
      inserted = nil
      allow(connection).to receive(:exec_params) do |sql, params|
        expect(sql).to include("INSERT INTO responses")
        inserted = params
      end

      recorder.maybe_record_response(req, chunks, upstream_result, timing: timing)
      inserted
    end

    def result(status:, headers: {}, retries: 0, error: nil)
      Jorm::UpstreamClient::Result.new(
        status: status,
        headers: headers,
        body: [],
        retries: retries,
        error: error
      )
    end

    it "parses and re-redacts a JSON response body, like the file recorder" do
      req = build_req
      upstream_result = result(
        status: 200,
        headers: { "content-type" => "application/json", "authorization" => "Bearer sk-secret" }
      )

      params = capture_response_params(req, ['{"key":"sk-', 'abcdefghijk"}'], upstream_result)
      _id, jorm_request_id, status, headers, body, ttft_ms, duration_ms, retry_count, error = params

      expect(jorm_request_id).to eq(req.jorm_request_id)
      expect(status).to eq(200)
      expect(headers).to include("***redacted***")
      expect(body).to eq('{"key":"sk-***redacted***"}')
      expect(ttft_ms).to be_nil
      expect(duration_ms).to be_nil
      expect(retry_count).to eq(0)
      expect(error).to be_nil
    end

    it "keeps a non-JSON response body as redacted raw text" do
      req = build_req
      upstream_result = result(
        status: 200,
        headers: { "content-type" => "text/event-stream" }
      )

      params = capture_response_params(req, ["chunk-one ", "sk-abcdefghijk"], upstream_result)
      body = params[4]

      expect(body).to eq("chunk-one sk-***redacted***")
    end

    it "records nil for an empty response body" do
      req = build_req
      upstream_result = result(status: 204, headers: {})

      params = capture_response_params(req, [], upstream_result)
      body = params[4]

      expect(body).to be_nil
    end

    it "records duration_ms from timing and ttft_ms = duration for non-streaming success" do
      req = build_req
      upstream_result = result(
        status: 200,
        headers: { "content-type" => "application/json" }
      )
      timing = { started_at: 100.0, chunk_times: [100.05], finished_at: 100.2 }

      params = capture_response_params(req, ['{"ok":true}'], upstream_result, timing: timing)
      _id, _jid, _status, _headers, _body, ttft_ms, duration_ms, _retries, error = params

      expect(duration_ms).to eq(200.0)
      expect(ttft_ms).to eq(200.0)
      expect(error).to be_nil
    end

    it "records ttft_ms from the first content_block_delta chunk for streaming" do
      req = build_req
      upstream_result = result(
        status: 200,
        headers: { "content-type" => "text/event-stream" }
      )
      chunks = [
        "event: message_start\ndata: {}\n\n",
        "event: content_block_delta\ndata: {\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n\n",
        "event: message_delta\ndata: {}\n\n"
      ]
      timing = {
        started_at: 10.0,
        chunk_times: [10.01, 10.05, 10.2],
        finished_at: 10.25
      }

      params = capture_response_params(req, chunks, upstream_result, timing: timing)
      _id, _jid, _status, _headers, _body, ttft_ms, duration_ms, _retries, error = params

      expect(duration_ms).to eq(250.0)
      expect(ttft_ms).to eq(50.0)
      expect(error).to be_nil
    end

    it "counts thinking deltas as the first token for TTFT" do
      req = build_req
      upstream_result = result(
        status: 200,
        headers: { "content-type" => "text/event-stream" }
      )
      chunks = [
        "event: content_block_delta\ndata: {\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"...\"}}\n\n"
      ]
      timing = { started_at: 1.0, chunk_times: [1.08], finished_at: 1.5 }

      params = capture_response_params(req, chunks, upstream_result, timing: timing)
      ttft_ms = params[5]

      expect(ttft_ms).to eq(80.0)
    end

    it "leaves ttft_ms nil on errors and records the error message" do
      req = build_req
      upstream_result = result(
        status: 502,
        headers: { "content-type" => "application/json" },
        retries: 1,
        error: "Connection reset by peer"
      )
      timing = { started_at: 1.0, chunk_times: [], finished_at: 1.1 }

      params = capture_response_params(
        req,
        ['{"error":{"message":"ignored"}}'],
        upstream_result,
        timing: timing
      )
      _id, _jid, status, _headers, _body, ttft_ms, duration_ms, retry_count, error = params

      expect(status).to eq(502)
      expect(ttft_ms).to be_nil
      expect(duration_ms).to eq(100.0)
      expect(retry_count).to eq(1)
      expect(error).to eq("Connection reset by peer")
    end

    it "derives error from a JSON error body when status >= 400" do
      req = build_req
      upstream_result = result(
        status: 429,
        headers: { "content-type" => "application/json" }
      )

      params = capture_response_params(
        req,
        ['{"error":{"type":"rate_limit","message":"Too many requests"}}'],
        upstream_result
      )
      error = params[8]

      expect(error).to eq("Too many requests")
    end

    it "derives error from an SSE mid-stream error event" do
      req = build_req
      upstream_result = result(
        status: 200,
        headers: { "content-type" => "text/event-stream" }
      )
      chunks = [
        "event: message_start\ndata: {\"message\":{}}\n\n",
        "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded\",\"message\":\"Overloaded\"}}\n\n"
      ]

      params = capture_response_params(req, chunks, upstream_result)
      _id, _jid, _status, _headers, _body, ttft_ms, _duration, _retries, error = params

      expect(error).to eq("Overloaded")
      expect(ttft_ms).to be_nil
    end

    it "falls back to http_<status> when no error message is available" do
      req = build_req
      upstream_result = result(status: 500, headers: { "content-type" => "text/plain" })

      params = capture_response_params(req, ["boom"], upstream_result)
      expect(params[8]).to eq("http_500")
    end
  end

  describe "when disabled" do
    subject(:recorder) { described_class.new(enabled: false) }

    it "does not touch a connection for record_request" do
      expect { recorder.record_request(build_req, "{}", false) }.not_to raise_error
    end

    it "does not touch a connection for maybe_record_response" do
      upstream_result = Jorm::UpstreamClient::Result.new(status: 200, headers: {})
      timing = { started_at: 1.0, chunk_times: [], finished_at: 1.1 }
      expect { recorder.maybe_record_response(build_req, ["x"], upstream_result, timing: timing) }.not_to raise_error
    end
  end
end
