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
    it "inserts a redacted row into requests" do
      req = build_req("HTTP_AUTHORIZATION" => "Bearer sk-secret")

      expect(connection).to receive(:exec_params) do |sql, params|
        expect(sql).to include("INSERT INTO requests")
        id, method, path, upstream_path, patched, headers, body = params
        expect(id).to eq(req.jorm_request_id)
        expect(method).to eq("POST")
        expect(path).to eq("/v1/messages")
        expect(upstream_path).to eq(Jorm::UpstreamClient.upstream_path(req))
        expect(patched).to eq(true)
        expect(headers).to include("***redacted***")
        expect(body).to eq('{"key":"sk-***redacted***"}')
      end

      recorder.record_request(req, '{"key":"sk-abcdefghijk"}', true)
    end
  end

  describe "#maybe_record_response" do
    it "inserts one row per chunk, with status/headers only on the first" do
      req = build_req
      upstream_result = Jorm::UpstreamClient::Result.new(
        status: 200,
        headers: { "content-type" => "application/json", "authorization" => "Bearer sk-secret" }
      )

      inserted = []
      allow(connection).to receive(:exec_params) do |_sql, params|
        inserted << params
      end

      recorder.maybe_record_response(req, ["chunk-one", "chunk-two"], upstream_result)

      expect(inserted.size).to eq(2)

      _id0, request_id0, index0, status0, headers0, body0 = inserted[0]
      expect(request_id0).to eq(req.jorm_request_id)
      expect(index0).to eq(0)
      expect(status0).to eq(200)
      expect(headers0).to include("***redacted***")
      expect(body0).to eq("chunk-one")

      _id1, request_id1, index1, status1, headers1, body1 = inserted[1]
      expect(request_id1).to eq(req.jorm_request_id)
      expect(index1).to eq(1)
      expect(status1).to be_nil
      expect(headers1).to be_nil
      expect(body1).to eq("chunk-two")
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
