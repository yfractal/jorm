# frozen_string_literal: true

module Jorm
  # inspired by https://github.com/dashxio/deepseek-claude-proxy
  module SecurityClassifier
    module_function

    # The classifier carries a system array with:
    # 1. A billing-header text block
    # 2. A "security monitor" prompt text block
    def match?(body)
      return false unless body.is_a?(Hash)

      system = body["system"]
      return false unless system.is_a?(Array)

      has_billing_header = system.any? do |s|
        s.is_a?(Hash) &&
          s["type"] == "text" &&
          s["text"].is_a?(String) &&
          s["text"].start_with?("x-anthropic-billing-header:")
      end

      has_security_monitor = system.any? do |s|
        s.is_a?(Hash) &&
          s["type"] == "text" &&
          s["text"].is_a?(String) &&
          s["text"].start_with?("You are a security monitor")
      end

      has_billing_header && has_security_monitor
    end

    def patch!(body)
      body["thinking"] = { "type" => "disabled" }
      body.delete("reasoning_effort")
      body.delete("output_config")
      body
    end
  end
end
