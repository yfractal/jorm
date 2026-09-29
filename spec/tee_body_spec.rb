# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Jorm::TeeBody do
  it "streams chunks to the client and collects them for on_complete" do
    source = %w[a b c]
    seen = []
    collected = nil

    body = described_class.new(source) { |chunks| collected = chunks }
    body.each { |chunk| seen << chunk }

    expect(seen).to eq(%w[a b c])
    expect(collected).to eq(%w[a b c])
  end

  it "passes monotonic chunk_times alongside chunks to on_complete" do
    source = %w[one two]
    got_chunks = nil
    got_times = nil

    body = described_class.new(source) do |chunks, chunk_times|
      got_chunks = chunks
      got_times = chunk_times
    end
    body.each { |_| }

    expect(got_chunks).to eq(%w[one two])
    expect(got_times.length).to eq(2)
    expect(got_times[0]).to be_a(Float)
    expect(got_times[1]).to be >= got_times[0]
  end

  it "still works with a one-argument on_complete block" do
    collected = nil
    body = described_class.new(["x"]) { |chunks| collected = chunks }
    body.each { |_| }
    expect(collected).to eq(["x"])
  end

  it "calls on_complete only once even if both each and close run" do
    calls = 0
    body = described_class.new(["x"]) { |_chunks, _times| calls += 1 }
    body.each { |_| }
    body.close
    expect(calls).to eq(1)
  end

  it "does not raise when on_complete fails" do
    body = described_class.new(["x"]) { raise "boom" }
    expect { body.each { |_| } }.not_to raise_error
  end
end
