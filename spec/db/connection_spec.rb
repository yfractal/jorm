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

    it "single-quotes string values and doubles embedded quotes" do
      expect(literal(%(it's fine))).to eq(%('it''s fine'))
    end

    it "leaves backslashes literal (no E'...' form)" do
      expect(literal('{"a":"b\\"c"}')).to eq(%('{"a":"b\\"c"}'))
    end

    it "rewrites embedded NUL bytes" do
      expect(literal("a\0b")).to eq(%('a\\u0000b'))
    end

    it "re-encodes BINARY strings as UTF-8 before quoting" do
      expect(literal("café".b)).to eq(%('café'))
    end

    it "passes through nil / bool / numbers" do
      expect(literal(nil)).to eq("NULL")
      expect(literal(true)).to eq("TRUE")
      expect(literal(false)).to eq("FALSE")
      expect(literal(42)).to eq("42")
    end
  end
end
