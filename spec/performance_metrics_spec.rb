# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Jorm::PerformanceMetrics do
  describe ".extract" do
    it "pulls model and usage from the response body" do
      metrics = described_class.extract(
        req_body: { "model" => "from-req" },
        resp_body: {
          "model" => "from-resp",
          "usage" => {
            "input_tokens" => 10,
            "output_tokens" => 20,
            "cache_read_input_tokens" => 3,
            "cache_creation_input_tokens" => 4,
            "output_tokens_details" => { "thinking_tokens" => 5 }
          }
        }
      )

      expect(metrics).to eq(
        model: "from-resp",
        think_effort: "(none)",
        input_tokens: 10,
        output_tokens: 20,
        cache_read_tokens: 3,
        cache_creation_tokens: 4,
        reasoning_tokens: 5
      )
    end

    it "falls back to the request model when the response has none" do
      metrics = described_class.extract(
        req_body: '{"model":"req-model","thinking":{"type":"adaptive"}}',
        resp_body: '{"usage":{"input_tokens":1,"output_tokens":2}}'
      )

      expect(metrics[:model]).to eq("req-model")
      expect(metrics[:think_effort]).to eq("adaptive")
      expect(metrics[:input_tokens]).to eq(1)
      expect(metrics[:output_tokens]).to eq(2)
    end
  end

  describe ".think_effort" do
    it "reads reasoning_effort, nested reasoning.effort, and thinking variants" do
      expect(described_class.think_effort({ "reasoning_effort" => "high" })).to eq("high")
      expect(described_class.think_effort({ "reasoning" => { "effort" => "low" } })).to eq("low")
      expect(described_class.think_effort({ "thinking" => false })).to eq("disabled")
      expect(described_class.think_effort({ "thinking" => true })).to eq("enabled")
      expect(described_class.think_effort({ "thinking" => { "type" => "disabled" } })).to eq("disabled")
      expect(described_class.think_effort({ "thinking" => { "budget_tokens" => 1024 } })).to eq("budget:1024")
      expect(described_class.think_effort({})).to eq("(none)")
    end
  end
end
