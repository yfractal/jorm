# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Jorm::CompositeRecorder do
  let(:good) { double("recorder") }
  let(:bad) { double("recorder") }
  let(:timing) { { started_at: 1.0, chunk_times: [1.1], finished_at: 1.2 } }

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

      expect { composite.maybe_record_response(:req, ["chunk"], :result, timing) }.not_to raise_error

      expect(good).to have_received(:maybe_record_response)
        .with(:req, ["chunk"], :result, timing)
    end

    it "forwards timing to every recorder" do
      allow(bad).to receive(:maybe_record_response)
      allow(good).to receive(:maybe_record_response)

      composite.maybe_record_response(:req, ["chunk"], :result, timing)

      expect(good).to have_received(:maybe_record_response)
        .with(:req, ["chunk"], :result, timing)
      expect(bad).to have_received(:maybe_record_response)
        .with(:req, ["chunk"], :result, timing)
    end
  end
end
