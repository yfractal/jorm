#!/usr/bin/env ruby
# frozen_string_literal: true

require "webrick"
require "net/http"
require "uri"
require "json"
require "securerandom"
require "time"
require "fileutils"

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8080

UPSTREAM = "https://openrouter.ai/api"

LOG_DIR = File.expand_path("~/.claude-code-logs")
DUMP_FILE = File.join(
  LOG_DIR,
  "dump-#{Time.now.utc.iso8601(3).tr(':', '-')}.jsonl"
)

# Headers that contain credentials and should NOT be persisted.
SENSITIVE_HEADERS = %w[
  authorization
  proxy-authorization
  x-api-key
  cookie
  set-cookie
].freeze


def utc_now
  Time.now.utc.iso8601(6)
end


def append_dump(record)
  FileUtils.mkdir_p(LOG_DIR)

  line = "#{JSON.generate(record)}\n"

  File.open(DUMP_FILE, File::WRONLY | File::APPEND | File::CREAT) do |f|
    f.flock(File::LOCK_EX)
    f.write(line)
  ensure
    f.flock(File::LOCK_UN)
  end
end


def sanitize_headers(headers)
  headers.each_with_object({}) do |(key, value), result|
    key = key.to_s.downcase

    if SENSITIVE_HEADERS.include?(key)
      result[key] = "[REDACTED]"
    else
      result[key] = value
    end
  end
end


def read_request_body(req)
  length = req.header["content-length"]&.first

  if length
    req.body.to_s
  else
    ""
  end
end

def parse_json_or_string(body)
  JSON.parse(body)
rescue JSON::ParserError
  # Ruby 3 freezes string literals (e.g. "" when there is no body); mutate a copy.
  body.to_s.dup
      .force_encoding("UTF-8")
      .encode("UTF-8", invalid: :replace, undef: :replace)
end

def utf8_text(bytes)
  bytes.to_s.dup
       .force_encoding("UTF-8")
       .encode("UTF-8", invalid: :replace, undef: :replace)
end


class ClaudeCodeProxy < WEBrick::HTTPServlet::AbstractServlet

  def do_GET(req, res)
    handle(req, res)
  end

  def do_POST(req, res)
    handle(req, res)
  end

  def do_PUT(req, res)
    handle(req, res)
  end

  def do_DELETE(req, res)
    handle(req, res)
  end

  def do_PATCH(req, res)
    handle(req, res)
  end

  private

  def handle(req, res)
    started_at = Process.clock_gettime(
      Process::CLOCK_MONOTONIC
    )

    request_id = "#{Time.now.strftime('%H-%M-%S')}-#{SecureRandom.hex(4)}"
    request_body = read_request_body(req)

    record = {
      request_id: request_id,
      started_at: utc_now,
      method: req.request_method,
      path: req.path,
      query_string: req.query_string,
      url: req.request_uri.to_s,
      request: {
        headers: sanitize_headers(req.header),
        body: parse_json_or_string(request_body)
      },
      response: nil,
      error: nil,
      completed_at: nil,
      duration_ms: nil
    }

    # ----------------------------------------------------------
    # UPSTREAM
    # ----------------------------------------------------------

    uri = URI.parse(
      UPSTREAM + req.path + (req.query_string ? "?#{req.query_string}" : "")
    )

    api_key = ENV["OPENROUTER_API_KEY"]

    unless api_key && !api_key.empty?
      res.status = 500
      res["Content-Type"] = "application/json"

      res.body = JSON.generate(
        error: "OPENROUTER_API_KEY is not set"
      )

      record[:error] = {
        error_class: "RuntimeError",
        error: "OPENROUTER_API_KEY is not set"
      }
      record[:completed_at] = utc_now
      record[:duration_ms] = (
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000
      ).round(2)
      append_dump(record)

      return
    end

    http = Net::HTTP.new(
      uri.host,
      uri.port
    )

    http.use_ssl = true

    http.open_timeout = 30

    # IMPORTANT:
    # Do not set read_timeout here.
    #
    # Claude Code can have long-running generations.
    http.read_timeout = nil

    upstream_request =
      case req.request_method

      when "POST"
        Net::HTTP::Post.new(uri)

      when "PUT"
        Net::HTTP::Put.new(uri)

      when "PATCH"
        Net::HTTP::Patch.new(uri)

      when "DELETE"
        Net::HTTP::Delete.new(uri)

      else
        Net::HTTP::Get.new(uri)
      end

    # ----------------------------------------------------------
    # REQUEST HEADERS TO UPSTREAM
    # ----------------------------------------------------------

    req.header.each do |key, values|
      next if key.downcase == "host"
      next if key.downcase == "content-length"
      next if key.downcase == "connection"

      upstream_request[key] = values.join(", ")
    end

    # Use the OpenRouter key.
    upstream_request["Authorization"] =
      "Bearer #{api_key}"

    # We don't want WEBrick's incoming auth token to leak.
    #
    # OpenRouter uses Bearer authentication.
    #
    upstream_request.body = request_body unless request_body.empty?

    record[:upstream_url] = uri.to_s

    # ----------------------------------------------------------
    # UPSTREAM STREAM
    # ----------------------------------------------------------

    begin

      http.request(upstream_request) do |upstream_response|
        chunks = []

        response_headers =
          sanitize_headers(
            upstream_response.each_header.to_h
          )

        res.status =
          upstream_response.code.to_i

        upstream_response.each_header do |key, value|

          next if key.downcase == "content-length"
          next if key.downcase == "transfer-encoding"
          next if key.downcase == "connection"

          res[key] = value
        end

        upstream_response.read_body do |chunk|
          chunks << chunk.dup

          # Forward untouched bytes to Claude Code
          res.body ||= ""
          res.body << chunk
        end

        body_text = utf8_text(chunks.join)

        record[:response] = {
          status: upstream_response.code.to_i,
          headers: response_headers,
          body: parse_json_or_string(body_text),
          bytes: chunks.sum(&:bytesize),
          chunks: chunks.size
        }
      end

    rescue StandardError => e

      record[:error] = {
        error_class: e.class.name,
        error: e.message,
        backtrace: e.backtrace
      }

      raise

    ensure

      duration =
        (
          Process.clock_gettime(
            Process::CLOCK_MONOTONIC
          ) - started_at
        ) * 1000

      record[:completed_at] = utc_now
      record[:duration_ms] = duration.round(2)

      append_dump(record)
    end
  end
end


FileUtils.mkdir_p(LOG_DIR)
FileUtils.touch(DUMP_FILE)

server = WEBrick::HTTPServer.new(
  BindAddress: LISTEN_HOST,
  Port: LISTEN_PORT,

  AccessLog: [],

  Logger: WEBrick::Log.new(
    $stdout,
    WEBrick::Log::INFO
  )
)

server.mount(
  "/",
  ClaudeCodeProxy
)

trap("INT") do
  server.shutdown
end

trap("TERM") do
  server.shutdown
end

puts
puts "Claude Code Ruby proxy"
puts
puts "Listening:"
puts "  http://#{LISTEN_HOST}:#{LISTEN_PORT}"
puts
puts "Upstream:"
puts "  #{UPSTREAM}"
puts
puts "Dump:"
puts "  #{DUMP_FILE}"
puts

server.start
