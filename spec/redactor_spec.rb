# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Jorm::Redactor do
  describe ".redact_headers" do
    it "redacts authorization and x-api-key, case-insensitively" do
      result = described_class.redact_headers(
        "Authorization" => "Bearer sk-secret",
        "X-Api-Key" => "sk-abc",
        "content-type" => "application/json"
      )

      expect(result["Authorization"]).to eq("***redacted***")
      expect(result["X-Api-Key"]).to eq("***redacted***")
      expect(result["content-type"]).to eq("application/json")
    end

    it "drops nil values" do
      result = described_class.redact_headers("x-foo" => nil, "x-bar" => "baz")
      expect(result).to eq("x-bar" => "baz")
    end
  end

  describe ".redact_body_text" do
    it "redacts sk- tokens" do
      text = '{"key":"sk-abcdefghijk"}'
      expect(described_class.redact_body_text(text)).to eq('{"key":"sk-***redacted***"}')
    end
  end

  describe ".parse_body" do
    it "parses JSON and redacts secrets" do
      raw = '{"token":"sk-abcdefghijk"}'
      result = described_class.parse_body(raw, "application/json")
      expect(result).to eq({ "token" => "sk-***redacted***" })
    end

    it "returns redacted text for non-JSON" do
      raw = "token=sk-abcdefghijk"
      expect(described_class.parse_body(raw, "text/plain")).to eq(
        "token=sk-***redacted***"
      )
    end

    it "returns nil for nil/empty input" do
      expect(described_class.parse_body(nil, "application/json")).to be_nil
      expect(described_class.parse_body("", "application/json")).to be_nil
    end

    it "falls back to raw text when JSON parsing fails" do
      raw = "not json"
      expect(described_class.parse_body(raw, "application/json")).to eq("not json")
    end
  end
end
