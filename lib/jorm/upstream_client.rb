# frozen_string_literal: true

require "async/http/client"
require "async/http/endpoint"
require "protocol/http/request"
require "protocol/http/headers"
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
      "#{Config::UPSTREAM_PREFIX}#{req.url.empty? ? "/" : req.url}"
    end

    def initialize(upstream_url: Config::UPSTREAM_URL)
      @endpoint = Async::HTTP::Endpoint.parse(upstream_url)
    end

    def call(req:, path:, body:)
      retried = false
      headers = HeaderFilter.copy_request_headers(req.headers, body.to_s.bytesize)

      begin
        client = Async::HTTP::Client.new(@endpoint)
        request = build_request(req.method, path, headers, body)
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
        body
      )
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
