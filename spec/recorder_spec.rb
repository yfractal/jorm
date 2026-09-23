# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "spec_helper"

RSpec.describe Rack::Recorder do
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

  describe "#record_response" do
    it "fills in status, headers, and body from the upstream result and chunks, then writes the record" do
      record = {}
      upstream_result = Jorm::UpstreamClient::Result.new(
        status: 200,
        headers: {
          "content-type" => "application/json",
          "authorization" => "Bearer sk-secret"
        }
      )

      recorder.maybe_record_response(record, ['{"token":"sk-abcdefghijk"}'], upstream_result)

      expect(record["response"]["status"]).to eq(200)
      expect(record["response"]["headers"]["authorization"]).to eq("***redacted***")
      expect(record["response"]["body"]).to eq({ "token" => "sk-***redacted***" })
      expect(Dir.children(dir).any? { |n| n.start_with?("res-") }).to eq(true)
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
