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

    it "assembles a streamed Anthropic-style SSE response into the non-streaming message shape" do
      raw = <<~SSE
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"m","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":0}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The user "}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"said hi."}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":"","citations":[]}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi "}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"there, my key is sk-abcdefghijk"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":10,"output_tokens":8}}

        event: message_stop
        data: {"type":"message_stop"}

        event: data
        data: [DONE]
      SSE

      result = described_class.parse_body(raw, "text/event-stream")

      expect(result).to eq(
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "m",
        "stop_reason" => "end_turn",
        "stop_sequence" => nil,
        "usage" => { "input_tokens" => 10, "output_tokens" => 8 },
        "content" => [
          { "type" => "thinking", "thinking" => "The user said hi.", "signature" => "" },
          { "type" => "text", "text" => "Hi there, my key is sk-***redacted***", "citations" => [] }
        ]
      )
    end

    it "falls back to raw text for a non-Anthropic-shaped SSE stream" do
      raw = "event: ping\ndata: {\"type\":\"ping\"}\n\n"
      expect(described_class.parse_body(raw, "text/event-stream")).to eq(raw)
    end
  end
end
