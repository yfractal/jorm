# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "spec_helper"

RSpec.describe DsProxy::DumpStore do
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(dir) }

  subject(:store) do
    described_class.new(
      enabled: true,
      dir: dir,
      dump_response: false,
      max_files: 2,
      max_age_hours: 0
    )
  end

  describe "#redact_headers" do
    it "redacts authorization and x-api-key" do
      result = store.redact_headers(
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
      expect(store.redact_body_text(text)).to eq('{"key":"sk-***redacted***"}')
    end
  end

  describe "#write and #cleanup!" do
    it "writes a dump file and prunes oldest when over max_files" do
      store.write("req", { "n" => 1 })
      sleep 0.05
      store.write("req", { "n" => 2 })
      sleep 0.05
      store.write("req", { "n" => 3 })

      files = Dir.children(dir).grep(/^(req|res)-.+\.json$/).sort
      expect(files.length).to eq(2)
    end

    it "removes files older than max_age_hours" do
      aged = described_class.new(
        enabled: true,
        dir: dir,
        dump_response: false,
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

  describe "#parse_body_for_dump" do
    it "parses JSON and redacts secrets" do
      raw = '{"token":"sk-abcdefghijk"}'
      result = store.parse_body_for_dump(raw, "application/json")
      expect(result).to eq({ "token" => "sk-***redacted***" })
    end

    it "returns redacted text for non-JSON" do
      raw = "token=sk-abcdefghijk"
      expect(store.parse_body_for_dump(raw, "text/plain")).to eq(
        "token=sk-***redacted***"
      )
    end
  end
end
