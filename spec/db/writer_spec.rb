# frozen_string_literal: true

require "timeout"
require_relative "../spec_helper"

RSpec.describe Jorm::Db::Writer do
  subject(:writer) { described_class.new }

  after { writer.close }

  it "runs enqueued jobs on a background thread" do
    results = Queue.new

    writer.enqueue { results.push(Thread.current) }

    job_thread = Timeout.timeout(1) { results.pop }
    expect(job_thread).not_to eq(Thread.current)
  end

  it "runs jobs in order" do
    results = Queue.new

    3.times { |i| writer.enqueue { results.push(i) } }

    seen = Array.new(3) { Timeout.timeout(1) { results.pop } }
    expect(seen).to eq([0, 1, 2])
  end

  it "rescues errors raised inside a job instead of propagating them" do
    results = Queue.new

    writer.enqueue { raise "boom" }
    writer.enqueue { results.push(:after_error) }

    expect(Timeout.timeout(1) { results.pop }).to eq(:after_error)
  end
end
