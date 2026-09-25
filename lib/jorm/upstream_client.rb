# frozen_string_literal: true

require "async/http/client"
require "async/http/endpoint"
require "protocol/http/request"
require "protocol/http/headers"
require "protocol/http/body/buffered"
require "openssl"

module Jorm
  class UpstreamClient
    RETRYABLE = [
      Errno::ECONNRESET,
      Errno::ETIMEDOUT,
      Errno::EPIPE,
      EOFError,
      OpenSSL::SSL::SSLError,
      Async::TimeoutError
    ].freeze

    # Wraps an Async::HTTP response body so the client is closed once
    # Falcon finishes streaming the response to the downstream client.
    class BoundBody
      def initialize(body, client)
        @body = body
        @client = client
        @closed = false
      end

      def each(&block)
        return enum_for(__method__) unless block

        @body.each(&block)
      end

      def close
        return if @closed

        @closed = true
        @body.close if @body.respond_to?(:close)
      ensure
        @client.close
      end

      def respond_to_missing?(name, include_private = false)
        @body.respond_to?(name, include_private) || super
      end

      def method_missing(name, ...)
        @body.public_send(name, ...)
      end
    end

    Result = Struct.new(:status, :headers, :body, keyword_init: true)

    def self.upstream_path(req)
      req.path_with_query_string || '/'
    end

    def initialize(upstream_url: Config::UPSTREAM_URL)
      @url = Async::HTTP::Endpoint.parse(upstream_url)
      # Async::HTTP::Client only uses @url's host/port/scheme to open the
      # connection -- unlike Net::HTTP, it does NOT prepend the endpoint's
      # own path (e.g. the "/api" in "https://openrouter.ai/api") onto
      # requests built from a plain path like "/v1/messages". We have to
      # do that ourselves, or requests silently land on the wrong route
      # upstream (e.g. openrouter.ai's marketing site instead of its API).
      @base_path = @url.path.to_s.chomp("/")
    end

    def call(req:, path:, body:)
      retried = false
      headers = HeaderFilter.copy_request_headers(req.headers)

      begin
        client = Async::HTTP::Client.new(@url)

        request = build_request(req.method, "#{@base_path}#{path}", headers, body)
        response = client.call(request)

        Result.new(
          status: response.status,
          headers: response.headers.to_h,
          body: BoundBody.new(response.body, client)
        )
      rescue *RETRYABLE => e
        client&.close
        unless retried
          retried = true
          warn "Upstream error: [#{error_code(e)}] #{e.message}"
          puts "  \u21B3 retrying..."
          retry
        end
        raise
      rescue StandardError => e
        client&.close
        warn "Upstream error: [#{e.class}] #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}"

        Result.new(
          status: 502,
          headers: { "content-type" => "application/json; charset=utf-8" },
          body: [JSON.generate({ "error" => "upstream_error", "message" => e.message })]
        )
      end
    end

    private

    def build_request(method, path, headers, body)
      protocol_headers = Protocol::HTTP::Headers[headers.to_a]
      Protocol::HTTP::Request.new(
        nil,
        nil,
        method.to_s.upcase,
        path,
        nil,
        protocol_headers,
        wrap_body(body)
      )
    end

    # Async::HTTP (in particular its HTTP/2 implementation) expects the
    # request body to be a Protocol::HTTP::Body object (responding to
    # e.g. #stream?), not a raw String. Passing a plain String worked
    # accidentally under HTTP/1.1 but raises
    # `NoMethodError: undefined method 'stream?' for an instance of String`
    # once the connection negotiates HTTP/2 (e.g. against openrouter.ai).
    def wrap_body(body)
      return nil if body.nil? || body.empty?

      Protocol::HTTP::Body::Buffered.wrap(body)
    end

    def error_code(error)
      if error.respond_to?(:errno)
        Errno.constants.find { |c| Errno.const_get(c)::Errno == error.errno } || "no_code"
      else
        error.class.name
      end
    rescue StandardError
      "no_code"
    end
  end
end
