# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require_relative "spec_helper"

RSpec.describe Jorm::Recorder do
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(dir) }

  subject(:recorder) do
    described_class.new(
      enabled: true,
      dir: dir
    )
  end

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

  def written_records(type)
    File.readlines(recorder.file_path).map { |line| JSON.parse(line) }.select { |r| r["type"] == type }
  end

  describe "#initialize" do
    it "creates a single dump file eagerly" do
      expect(File).to exist(recorder.file_path)
      expect(recorder.file_path.to_s).to end_with(".jsonl")
    end

    it "reuses an explicit file_name so multiple instances share one file" do
      shared_name = "dump-shared.jsonl"
      first = described_class.new(enabled: true, dir: dir, file_name: shared_name)
      second = described_class.new(enabled: true, dir: dir, file_name: shared_name)

      expect(first.file_path).to eq(second.file_path)
      expect(Dir.children(dir)).to eq([shared_name])
    end

    it "defaults file_name from Jorm::Config.record_file (JO_DUMP_FILE)" do
      allow(Jorm::Config).to receive(:record_file).and_return("dump-from-env.jsonl")

      recorder = described_class.new(enabled: true, dir: dir)

      expect(recorder.file_path.to_s).to end_with("dump-from-env.jsonl")
    end
  end

  describe "concurrent writes" do
    it "does not interleave lines written from multiple threads/processes" do
      threads = Array.new(8) do |i|
        Thread.new { recorder.write("req", { "n" => i }) }
      end
      threads.each(&:join)

      lines = File.readlines(recorder.file_path)
      expect(lines.length).to eq(8)
      expect(lines.map { |l| JSON.parse(l)["n"] }.sort).to eq((0..7).to_a)
    end
  end

  describe "#redact_headers" do
    it "redacts authorization and x-api-key" do
      result = recorder.redact_headers(
        "authorization" => "Bearer sk-secret",
        "x-api-key" => "sk-abc",
        "content-type" => "application/json"
      )

      expect(result["authorization"]).to eq("***redacted***")
      expect(result["x-api-key"]).to eq("***redacted***")
      expect(result["content-type"]).to eq("application/json")
    end
  end

  describe "#redact_body_text" do
    it "redacts sk- tokens" do
      text = '{"key":"sk-abcdefghijk"}'
      expect(recorder.redact_body_text(text)).to eq('{"key":"sk-***redacted***"}')
    end
  end

  describe "#write" do
    it "appends every record to the single dump file" do
      recorder.write("req", { "n" => 1 })
      recorder.write("req", { "n" => 2 })
      recorder.write("req", { "n" => 3 })

      records = written_records("req")
      expect(records.map { |r| r["n"] }).to eq([1, 2, 3])
    end
  end

  describe "#record_request" do
    it "builds and writes a request record tagged with the request's jorm_request_id" do
      req = build_req("rack.input" => StringIO.new('{"model":"x"}'))

      recorder.record_request(req, '{"model":"x","patched":true}', true)

      record = written_records("req").first
      expect(record["jormRequestId"]).to eq(req.jorm_request_id)
      expect(record["method"]).to eq("POST")
      expect(record["path_with_query_string"]).to eq("/v1/messages")
      expect(record["patched"]).to eq(true)
      expect(record["request"]["body"]).to eq("model" => "x")
      expect(record["request"]["patchedBody"]).to eq("model" => "x", "patched" => true)
    end

    it "redacts sensitive request headers before writing" do
      req = build_req(
        "HTTP_AUTHORIZATION" => "Bearer sk-secret",
        "HTTP_X_API_KEY" => "sk-abc"
      )

      recorder.record_request(req, '{"patched":true}', true)

      headers = written_records("req").first["request"]["headers"]
      expect(headers["authorization"]).to eq("***redacted***")
      expect(headers["x-api-key"]).to eq("***redacted***")
    end

    it "records the original request body parsed and redacted" do
      req = build_req("rack.input" => StringIO.new('{"token":"sk-abcdefghijk"}'))

      recorder.record_request(req, '{"token":"sk-***redacted***","patched":true}', true)

      record = written_records("req").first
      expect(record["request"]["body"]).to eq("token" => "sk-***redacted***")
    end

    it "records the patched body separately when the request was patched" do
      req = build_req("rack.input" => StringIO.new('{"model":"x"}'))

      recorder.record_request(req, '{"model":"x","patched":true}', true)

      record = written_records("req").first
      expect(record["request"]["patchedBody"]).to eq("model" => "x", "patched" => true)
    end

    it "omits patchedBody when the request was not patched" do
      req = build_req("rack.input" => StringIO.new('{"model":"x"}'))

      recorder.record_request(req, '{"model":"x"}', false)

      record = written_records("req").first
      expect(record["request"]).not_to have_key("patchedBody")
    end

    it "does not emit BINARY strings, which JSON.generate warns on" do
      req = build_req("rack.input" => StringIO.new('{"text":"café"}'.b))

      recorder.record_request(req, '{"text":"café","patched":true}'.b, true)

      record = written_records("req").first
      expect(record["request"]["body"]).to eq("text" => "café")
      expect(record["request"]["body"]["text"].encoding).to eq(Encoding::UTF_8)
    end
  end

  describe "#maybe_record_response" do
    let(:timing) { { started_at: 1.0, chunk_times: [1.05], finished_at: 1.2 } }

    it "builds and writes a response record tagged with the request's jorm_request_id" do
      req = build_req
      upstream_result = Jorm::UpstreamClient::Result.new(
        status: 200,
        headers: {
          "content-type" => "application/json",
          "authorization" => "Bearer sk-secret"
        },
        retries: 0
      )

      recorder.maybe_record_response(req, ['{"token":"sk-abcdefghijk"}'], upstream_result, timing)

      record = written_records("res").first
      expect(record["jormRequestId"]).to eq(req.jorm_request_id)
      expect(record["response"]["status"]).to eq(200)
      expect(record["response"]["headers"]["authorization"]).to eq("***redacted***")
      expect(record["response"]["body"]).to eq({ "token" => "sk-***redacted***" })
      expect(record["response"]["retries"]).to eq(0)
      expect(record["response"]["timing"]).to eq(
        "startedAt" => 1.0,
        "chunkTimes" => [1.05],
        "finishedAt" => 1.2
      )
    end

    it "re-encodes a BINARY response buffer as UTF-8 so JSON.generate doesn't warn" do
      req = build_req
      upstream_result = Jorm::UpstreamClient::Result.new(
        status: 200,
        headers: { "content-type" => "text/plain" },
        retries: 0
      )

      recorder.maybe_record_response(req, ['{"text":"café"}'.b], upstream_result, timing)

      record = written_records("res").first
      expect(record["response"]["body"]).to eq('{"text":"café"}')
      expect(record["response"]["body"].encoding).to eq(Encoding::UTF_8)
    end

    it "persists timing, retries and error when provided" do
      req = build_req
      upstream_result = Jorm::UpstreamClient::Result.new(
        status: 502,
        headers: { "content-type" => "application/json" },
        retries: 1,
        error: "timeout"
      )

      recorder.maybe_record_response(req, ['{"error":"timeout"}'], upstream_result, timing)

      record = written_records("res").first
      expect(record["response"]["retries"]).to eq(1)
      expect(record["response"]["error"]).to eq("timeout")
      expect(record["response"]["timing"]).to eq(
        "startedAt" => 1.0,
        "chunkTimes" => [1.05],
        "finishedAt" => 1.2
      )
    end
  end

  describe "#parse_body" do
    it "parses JSON and redacts secrets" do
      raw = '{"token":"sk-abcdefghijk"}'
      result = recorder.parse_body(raw, "application/json")
      expect(result).to eq({ "token" => "sk-***redacted***" })
    end

    it "returns redacted text for non-JSON" do
      raw = "token=sk-abcdefghijk"
      expect(recorder.parse_body(raw, "text/plain")).to eq(
        "token=sk-***redacted***"
      )
    end
  end
end
