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
      if content_type.to_s.include?("application/json")
        JSON.parse(raw)
      else
        raw
      end
    rescue JSON::ParserError
      raw
    end
  end
end
