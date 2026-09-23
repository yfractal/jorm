# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Jorm::HeaderFilter do
  describe ".from_rack_env" do
    it "extracts HTTP_* headers and content-type/length" do
      env = {
        "HTTP_X_API_KEY" => "secret",
        "HTTP_ACCEPT" => "application/json",
        "CONTENT_TYPE" => "application/json",
        "CONTENT_LENGTH" => "12",
        "PATH_INFO" => "/v1/messages"
      }

      headers = described_class.from_rack_env(env)

      expect(headers["x-api-key"]).to eq("secret")
      expect(headers["accept"]).to eq("application/json")
      expect(headers["content-type"]).to eq("application/json")
      expect(headers["content-length"]).to eq("12")
      expect(headers).not_to have_key("path-info")
    end
  end

  describe ".copy_request_headers" do
    it "strips hop-by-hop, host, and recomputes content-length" do
      headers = {
        "host" => "localhost",
        "content-length" => "999",
        "connection" => "keep-alive",
        "x-api-key" => "secret",
        "content-type" => "application/json"
      }

      result = described_class.copy_request_headers(headers, 42)

      expect(result).not_to have_key("host")
      expect(result).not_to have_key("connection")
      expect(result["content-length"]).to eq("42")
      expect(result["x-api-key"]).to eq("secret")
      expect(result["content-type"]).to eq("application/json")
    end
  end

  describe ".copy_response_headers" do
    it "strips hop-by-hop headers" do
      headers = {
        "content-type" => "application/json",
        "transfer-encoding" => "chunked",
        "connection" => "close"
      }

      result = described_class.copy_response_headers(headers)

      expect(result["content-type"]).to eq("application/json")
      expect(result).not_to have_key("transfer-encoding")
      expect(result).not_to have_key("connection")
    end
  end
end
