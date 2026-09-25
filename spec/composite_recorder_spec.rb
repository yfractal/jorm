# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Jorm::CompositeRecorder do
  let(:good) { double("recorder") }
  let(:bad) { double("recorder") }

  subject(:composite) { described_class.new([bad, good]) }

  describe "#record_request" do
    it "calls record_request on every recorder" do
      allow(bad).to receive(:record_request)
      allow(good).to receive(:record_request)

      composite.record_request(:req, "body", true)

      expect(bad).to have_received(:record_request).with(:req, "body", true)
      expect(good).to have_received(:record_request).with(:req, "body", true)
    end

    it "isolates a recorder that raises so others still run" do
      allow(bad).to receive(:record_request).and_raise("boom")
      allow(good).to receive(:record_request)

      expect { composite.record_request(:req, "body", true) }.not_to raise_error

      expect(good).to have_received(:record_request)
    end
  end

  describe "#maybe_record_response" do
    it "calls maybe_record_response on every recorder, isolating failures" do
      allow(bad).to receive(:maybe_record_response).and_raise("boom")
      allow(good).to receive(:maybe_record_response)

      expect { composite.maybe_record_response(:req, ["chunk"], :result) }.not_to raise_error

      expect(good).to have_received(:maybe_record_response).with(:req, ["chunk"], :result)
    end
  end
end
