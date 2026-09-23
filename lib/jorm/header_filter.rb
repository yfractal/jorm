# frozen_string_literal: true

module Jorm
  module HeaderFilter
    module_function

    HOP_BY_HOP = %w[
      connection
      keep-alive
      proxy-authenticate
      proxy-authorization
      te
      trailer
      transfer-encoding
      upgrade
    ].freeze

    # Extract HTTP headers from a Rack env into a flat Hash of
    # lowercase header names => string values.
    def from_rack_env(env)
      headers = {}

      env.each do |key, value|
        next unless key.start_with?("HTTP_")
        next if value.nil?

        name = key[5..].downcase.tr("_", "-")
        headers[name] = value
      end

      if env["CONTENT_TYPE"]
        headers["content-type"] = env["CONTENT_TYPE"]
      end

      if env["CONTENT_LENGTH"]
        headers["content-length"] = env["CONTENT_LENGTH"]
      end

      headers
    end

    def copy_request_headers(headers, body_length)
      result = {}

      headers.each do |name, value|
        lower = name.downcase
        next if lower == "host"
        next if lower == "content-length"
        next if HOP_BY_HOP.include?(lower)
        next if value.nil?

        result[name] = value
      end

      result["content-length"] = body_length.to_s
      result
    end

    def copy_response_headers(headers)
      result = {}

      headers.each do |name, value|
        lower = name.to_s.downcase
        next if HOP_BY_HOP.include?(lower)
        next if value.nil?

        result[name.to_s] = value.is_a?(Array) ? value.join(", ") : value.to_s
      end

      result
    end
  end
end
