# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Jorm::Db::Connection do
  subject(:connection) do
    described_class.new(
      host: "127.0.0.1",
      port: 1,
      dbname: "unused",
      user: nil,
      password: nil
    )
  end

  describe "#literal (via interpolate)" do
    def literal(value)
      connection.send(:literal, value)
    end

    it "dollar-quotes string values" do
      expect(literal('{"a":1}')).to eq(%($jorm${"a":1}$jorm$))
    end

    it "grows the tag when the value already contains $jorm$" do
      expect(literal("x$jorm$y")).to eq("$jorm_r$x$jorm$y$jorm_r$")
    end

    it "rewrites embedded NUL bytes" do
      expect(literal("a\0b")).to eq("$jorm$a\\u0000b$jorm$")
    end

    it "re-encodes BINARY strings as UTF-8 before quoting" do
      expect(literal("café".b)).to eq("$jorm$café$jorm$")
    end

    it "passes through nil / bool / numbers" do
      expect(literal(nil)).to eq("NULL")
      expect(literal(true)).to eq("TRUE")
      expect(literal(false)).to eq("FALSE")
      expect(literal(42)).to eq("42")
    end
  end
end
