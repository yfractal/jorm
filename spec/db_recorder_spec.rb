# frozen_string_literal: true

require "stringio"
require_relative "spec_helper"

RSpec.describe Jorm::DbRecorder do
  # Runs enqueued jobs synchronously, inline -- no real thread/DB needed.
  class InlineWriter
    def enqueue(&block)
      block.call
    end
  end

  let(:connection) { instance_double(Jorm::Db::Connection) }
  let(:writer) { InlineWriter.new }

  subject(:recorder) { described_class.new(enabled: true, connection: connection, writer: writer) }

  def build_req(overrides = {})
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/v1/messages",
      "QUERY_STRING" => "",
      "rack.input" => StringIO.new(""),
      "CONTENT_TYPE" => "application/json"
    }.merge(overrides)
    Jorm::Request.new(env)
  end

  describe "#record_request" do
    it "inserts a redacted row into requests, without recording the body" do
      req = build_req("HTTP_AUTHORIZATION" => "Bearer sk-secret")

      expect(connection).to receive(:exec_params) do |sql, params|
        expect(sql).to include("INSERT INTO requests")
        id, jorm_request_id, method, path, upstream_path, patched, headers = params
        expect(id).to match(/\A[0-9a-f-]{36}\z/)
        expect(id).not_to eq(req.jorm_request_id)
        expect(jorm_request_id).to eq(req.jorm_request_id)
        expect(method).to eq("POST")
        expect(path).to eq("/v1/messages")
        expect(upstream_path).to eq(Jorm::UpstreamClient.upstream_path(req))
        expect(patched).to eq(true)
        expect(headers).to include("***redacted***")
      end

      recorder.record_request(req, '{"key":"sk-abcdefghijk"}', true)
    end
  end

  describe "#maybe_record_response" do
    it "inserts a single redacted row into responses, without recording the body" do
      req = build_req
      upstream_result = Jorm::UpstreamClient::Result.new(
        status: 200,
        headers: { "content-type" => "application/json", "authorization" => "Bearer sk-secret" }
      )

      inserted = []
      allow(connection).to receive(:exec_params) do |sql, params|
        expect(sql).to include("INSERT INTO responses")
        inserted << params
      end

      recorder.maybe_record_response(req, ["chunk-one", "chunk-two"], upstream_result)

      expect(inserted.size).to eq(1)

      _id, jorm_request_id, status, headers = inserted[0]
      expect(jorm_request_id).to eq(req.jorm_request_id)
      expect(status).to eq(200)
      expect(headers).to include("***redacted***")
    end
  end

  describe "when disabled" do
    subject(:recorder) { described_class.new(enabled: false) }

    it "does not touch a connection for record_request" do
      expect { recorder.record_request(build_req, "{}", false) }.not_to raise_error
    end

    it "does not touch a connection for maybe_record_response" do
      upstream_result = Jorm::UpstreamClient::Result.new(status: 200, headers: {})
      expect { recorder.maybe_record_response(build_req, ["x"], upstream_result) }.not_to raise_error
    end
  end
end
