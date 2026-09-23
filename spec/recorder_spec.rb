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
      dir: dir,
      record_response: false,
      max_files: 2,
      max_age_hours: 0
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

  def written_record(prefix)
    files = Dir.children(dir).select { |n| n.start_with?("#{prefix}-") }
    JSON.parse(File.read(File.join(dir, files.first)))
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

  describe "#write and #cleanup!" do
    it "writes a record file and prunes oldest when over max_files" do
      recorder.write("req", { "n" => 1 })
      sleep 0.05
      recorder.write("req", { "n" => 2 })
      sleep 0.05
      recorder.write("req", { "n" => 3 })

      files = Dir.children(dir).grep(/^(req|res)-.+\.json$/).sort
      expect(files.length).to eq(2)
    end

    it "removes files older than max_age_hours" do
      aged = described_class.new(
        enabled: true,
        dir: dir,
        record_response: false,
        max_files: 0,
        max_age_hours: 1
      )

      path = File.join(dir, "req-old.json")
      File.write(path, "{}")
      File.utime(Time.now - 7200, Time.now - 7200, path)

      aged.write("req", { "n" => 1 })

      names = Dir.children(dir)
      expect(names).not_to include("req-old.json")
      expect(names.any? { |n| n.start_with?("req-") }).to eq(true)
    end
  end

  describe "#record_request" do
    it "builds and writes a request record tagged with the request's jorm_request_id" do
      req = build_req("rack.input" => StringIO.new('{"key":"sk-abcdefghijk"}'))

      recorder.record_request(req, '{"patched":true}', true)

      record = written_record("req")
      expect(record["jormRequestId"]).to eq(req.jorm_request_id)
      expect(record["method"]).to eq("POST")
      expect(record["patched"]).to eq(true)
      expect(record["request"]["body"]).to eq({ "key" => "sk-***redacted***" })
      expect(record["request"]["patchedBody"]).to eq({ "patched" => true })
    end
  end

  describe "#maybe_record_response" do
    it "builds and writes a response record tagged with the request's jorm_request_id" do
      req = build_req
      upstream_result = Jorm::UpstreamClient::Result.new(
        status: 200,
        headers: {
          "content-type" => "application/json",
          "authorization" => "Bearer sk-secret"
        }
      )

      recorder.maybe_record_response(req, ['{"token":"sk-abcdefghijk"}'], upstream_result)

      record = written_record("res")
      expect(record["jormRequestId"]).to eq(req.jorm_request_id)
      expect(record["response"]["status"]).to eq(200)
      expect(record["response"]["headers"]["authorization"]).to eq("***redacted***")
      expect(record["response"]["body"]).to eq({ "token" => "sk-***redacted***" })
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
