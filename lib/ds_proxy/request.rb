# frozen_string_literal: true

module DsProxy
  # Thin wrapper around a Rack env hash exposing the bits of the
  # incoming request the proxy cares about, with memoized access.
  class Request
    def initialize(env)
      @env = env
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
    def url
      @url ||= query_string.to_s.empty? ? path : "#{path}?#{query_string}"
    end

    def headers
      @headers ||= HeaderFilter.from_rack_env(@env)
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
