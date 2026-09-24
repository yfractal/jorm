# frozen_string_literal: true

require "rspec"

ENV["UPSTREAM_URL"] ||= "https://api.deepseek.com"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

require_relative "../lib/jorm"
