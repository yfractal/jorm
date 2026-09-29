# frozen_string_literal: true

require "securerandom"

module Jorm
  # Thin wrapper around a Rack env hash exposing the bits of the
  # incoming request the proxy cares about, with memoized access.
  class Request
    attr_reader :started_at

    def initialize(env)
      @env = env
      # Monotonic clock so duration / TTFT aren't skewed by wall-clock jumps.
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def method
      @env["REQUEST_METHOD"]
    end

    def path
      @path ||= @env["PATH_INFO"].to_s
    end

    def query_string
      @env["QUERY_STRING"]
    end

    # Path plus query string, e.g. "/v1/messages?foo=bar".
    def path_with_query_string
      @path_with_query_string ||= query_string.to_s.empty? ? path : "#{path}?#{query_string}"
    end

    def headers
      @headers ||= Jorm::HeaderFilter.from_rack_env(@env)
    end

    def content_type
      @content_type ||= headers["content-type"].to_s
    end

    def health_check?
      path == "/health"
    end

    def body
      @body ||= read_body
    end

    # A UUID identifying this request, generated once and cached for the
    # lifetime of the request so request/response records can be tied
    # together.
    def jorm_request_id
      @jorm_request_id ||= SecureRandom.uuid
    end

    private

    def read_body
      input = @env["rack.input"]
      return "" unless input

      input.read.to_s
    ensure
      input.rewind if input.respond_to?(:rewind)
    end
  end
end
