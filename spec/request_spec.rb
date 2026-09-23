# frozen_string_literal: true

require "stringio"

RSpec.describe DsProxy::Request do
  def build_env(overrides = {})
    {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/v1/messages",
      "QUERY_STRING" => "",
      "rack.input" => StringIO.new(""),
      "CONTENT_TYPE" => "application/json",
      "HTTP_X_API_KEY" => "secret"
    }.merge(overrides)
  end

  describe "#method" do
    it "returns the HTTP method" do
      req = described_class.new(build_env("REQUEST_METHOD" => "GET"))
      expect(req.method).to eq("GET")
    end
  end

  describe "#path" do
    it "returns PATH_INFO" do
      req = described_class.new(build_env("PATH_INFO" => "/health"))
      expect(req.path).to eq("/health")
    end
  end

  describe "#url" do
    it "returns just the path when there is no query string" do
      req = described_class.new(build_env("QUERY_STRING" => ""))
      expect(req.url).to eq("/v1/messages")
    end

    it "appends the query string when present" do
      req = described_class.new(build_env("QUERY_STRING" => "foo=bar"))
      expect(req.url).to eq("/v1/messages?foo=bar")
    end
  end

  describe "#headers" do
    it "delegates to HeaderFilter.from_rack_env and memoizes the result" do
      req = described_class.new(build_env)
      expect(req.headers["x-api-key"]).to eq("secret")
      expect(req.headers).to be(req.headers)
    end
  end

  describe "#content_type" do
    it "reads content-type from headers" do
      req = described_class.new(build_env("CONTENT_TYPE" => "text/plain"))
      expect(req.content_type).to eq("text/plain")
    end
  end

  describe "#health_check?" do
    it "is true for /health" do
      req = described_class.new(build_env("PATH_INFO" => "/health"))
      expect(req.health_check?).to be(true)
    end

    it "is false otherwise" do
      req = described_class.new(build_env("PATH_INFO" => "/v1/messages"))
      expect(req.health_check?).to be(false)
    end
  end

  describe "#body" do
    it "reads and memoizes rack.input" do
      input = StringIO.new("hello")
      req = described_class.new(build_env("rack.input" => input))
      expect(req.body).to eq("hello")
      expect(req.body).to eq("hello")
    end

    it "returns an empty string when rack.input is missing" do
      req = described_class.new(build_env("rack.input" => nil))
      expect(req.body).to eq("")
    end

    it "rewinds the input after reading" do
      input = StringIO.new("hello")
      req = described_class.new(build_env("rack.input" => input))
      req.body
      expect(input.pos).to eq(0)
    end
  end
end
