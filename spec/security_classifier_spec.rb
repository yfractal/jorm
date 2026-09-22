# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe DsProxy::SecurityClassifier do
  def classifier_body
    {
      "model" => "claude-sonnet-4-20250514",
      "system" => [
        {
          "type" => "text",
          "text" => "x-anthropic-billing-header: abc"
        },
        {
          "type" => "text",
          "text" => "You are a security monitor for this session."
        }
      ],
      "reasoning_effort" => "high",
      "output_config" => { "foo" => 1 }
    }
  end

  describe ".match?" do
    it "returns true for security classifier payloads" do
      expect(described_class.match?(classifier_body)).to eq(true)
    end

    it "returns false when billing header is missing" do
      body = classifier_body
      body["system"].shift
      expect(described_class.match?(body)).to eq(false)
    end

    it "returns false when security monitor prompt is missing" do
      body = classifier_body
      body["system"].pop
      expect(described_class.match?(body)).to eq(false)
    end

    it "returns false for non-hash bodies" do
      expect(described_class.match?(nil)).to eq(false)
      expect(described_class.match?([])).to eq(false)
    end

    it "returns false when system is not an array" do
      expect(described_class.match?({ "system" => "x" })).to eq(false)
    end
  end

  describe ".patch!" do
    it "disables thinking and removes legacy params" do
      body = classifier_body
      described_class.patch!(body)

      expect(body["thinking"]).to eq({ "type" => "disabled" })
      expect(body).not_to have_key("reasoning_effort")
      expect(body).not_to have_key("output_config")
    end
  end
end
