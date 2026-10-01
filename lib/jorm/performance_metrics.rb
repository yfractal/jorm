# frozen_string_literal: true

require "json"

module Jorm
  # Extracts the small set of fields the LLM performance report needs from
  # request/response bodies, so DbRecorder can persist them as real columns
  # and the report can query without joining or shipping full body text.
  module PerformanceMetrics
    module_function

    def extract(req_body:, resp_body:)
      req = coerce_hash(req_body)
      resp = coerce_hash(resp_body)
      usage = resp.is_a?(Hash) ? resp["usage"] : nil
      usage = {} unless usage.is_a?(Hash)
      details = usage["output_tokens_details"]

      model = ""
      model = resp["model"].to_s if resp.is_a?(Hash)
      model = req["model"].to_s if model.empty? && req.is_a?(Hash)

      {
        model: model,
        think_effort: think_effort(req),
        input_tokens: to_i(usage["input_tokens"]),
        output_tokens: to_i(usage["output_tokens"]),
        cache_read_tokens: to_i(usage["cache_read_input_tokens"]),
        cache_creation_tokens: to_i(usage["cache_creation_input_tokens"]),
        reasoning_tokens: details.is_a?(Hash) ? to_i(details["thinking_tokens"]) : 0
      }
    end

    def think_effort(req_body)
      body = coerce_hash(req_body)
      return "(none)" unless body.is_a?(Hash)

      effort = body["reasoning_effort"] || body.dig("reasoning", "effort") || body.dig("output_config", "effort")
      return effort.to_s if effort

      thinking = body["thinking"]
      case thinking
      when nil
        "(none)"
      when false
        "disabled"
      when true
        "enabled"
      when Hash
        if thinking["type"].to_s == "disabled"
          "disabled"
        elsif thinking.key?("budget_tokens")
          "budget:#{thinking["budget_tokens"]}"
        elsif thinking["type"]
          thinking["type"].to_s
        else
          thinking.inspect
        end
      else
        thinking.to_s
      end
    end

    def coerce_hash(value)
      case value
      when Hash then value
      when String
        return nil if value.empty?

        JSON.parse(value)
      end
    rescue JSON::ParserError
      nil
    end

    def to_i(value)
      Integer(value || 0)
    rescue ArgumentError, TypeError
      0
    end
  end
end
