# frozen_string_literal: true

require "json"

module Jorm
  # Shared redaction/parsing helpers used by every recorder (file-based
  # Recorder and DbRecorder) before persisting request/response traffic,
  # so sensitive data never reaches disk or the DB.
  module Redactor
    module_function

    def redact_headers(headers)
      redacted = {}

      headers.each do |name, value|
        lower = name.to_s.downcase
        if lower == "x-api-key" || lower == "authorization"
          redacted[name] = "***redacted***"
        elsif !value.nil?
          redacted[name] = value
        end
      end

      redacted
    end

    def redact_body_text(text)
      text.gsub(/sk-[A-Za-z0-9_-]{6,}/, "sk-***redacted***")
    end

    def parse_body(raw_bytes, content_type)
      return nil if raw_bytes.nil? || raw_bytes.empty?

      raw = redact_body_text(raw_bytes.dup.force_encoding("UTF-8"))
      ct = content_type.to_s
      if ct.include?("application/json")
        JSON.parse(raw)
      elsif ct.include?("text/event-stream")
        parse_sse(raw) || raw
      else
        raw
      end
    rescue JSON::ParserError
      raw
    end

    # Folds an SSE stream (as sent by Anthropic-compatible /v1/messages
    # responses) back into the same shape a non-streaming request would
    # have returned -- one message hash with fully concatenated content
    # blocks -- instead of leaving it as one opaque text blob, or as a
    # flat list of raw deltas nobody would want to read. Returns nil if
    # no "message_start" event was found (so the caller falls back to
    # storing the raw text) rather than an empty/partial hash.
    def parse_sse(text)
      assemble_sse_message(sse_events(text))
    end

    # Splits the stream into "event: ...\ndata: ...\n\n" blocks and
    # JSON-parses each one's data payload, skipping blocks whose data
    # isn't JSON (e.g. the trailing "data: [DONE]" some providers send).
    def sse_events(text)
      text.split(/\n\n+/).filter_map do |block|
        event = nil
        data_lines = []

        block.each_line do |line|
          line = line.chomp
          if (rest = line[/\Aevent:\s*(.*)/, 1])
            event = rest
          elsif (rest = line[/\Adata:\s*(.*)/, 1])
            data_lines << rest
          end
        end

        next if data_lines.empty?

        begin
          { "event" => event, "data" => JSON.parse(data_lines.join("\n")) }
        rescue JSON::ParserError
          nil
        end
      end
    end

    # Replays message_start/content_block_start/content_block_delta/
    # content_block_stop/message_delta events -- the standard Anthropic
    # Messages streaming sequence -- to rebuild the final message.
    # Unrecognized event types (e.g. "ping") are ignored.
    def assemble_sse_message(events)
      message = nil
      blocks = {}

      events.each do |event|
        data = event["data"]
        next unless data.is_a?(Hash)

        case event["event"]
        when "message_start"
          message = (data["message"] || {}).dup
        when "content_block_start"
          blocks[data["index"]] = (data["content_block"] || {}).dup
        when "content_block_delta"
          apply_content_block_delta(blocks[data["index"]], data["delta"])
        when "content_block_stop"
          finalize_content_block(blocks[data["index"]])
        when "message_delta"
          next unless message

          message.merge!(data["delta"]) if data["delta"].is_a?(Hash)
          message["usage"] = (message["usage"] || {}).merge(data["usage"]) if data["usage"].is_a?(Hash)
        end
      end

      return nil unless message

      message["content"] = blocks.keys.sort.map { |index| blocks[index] }
      message
    end

    # Appends one delta onto its content block -- text/thinking/signature
    # deltas concatenate onto a string field; a tool call's
    # input_json_delta accumulates onto a scratch key that
    # finalize_content_block parses once the block is complete.
    def apply_content_block_delta(block, delta)
      return unless block && delta.is_a?(Hash)

      case delta["type"]
      when "text_delta"
        block["text"] = "#{block["text"]}#{delta["text"]}"
      when "thinking_delta"
        block["thinking"] = "#{block["thinking"]}#{delta["thinking"]}"
      when "signature_delta"
        block["signature"] = "#{block["signature"]}#{delta["signature"]}"
      when "input_json_delta"
        block["_partial_json"] = "#{block["_partial_json"]}#{delta["partial_json"]}"
      end
    end

    def finalize_content_block(block)
      return unless block&.key?("_partial_json")

      raw_json = block.delete("_partial_json")
      block["input"] = begin
        JSON.parse(raw_json)
      rescue JSON::ParserError
        raw_json
      end
    end
  end
end
