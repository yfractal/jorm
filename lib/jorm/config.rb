# frozen_string_literal: true

require "pathname"

module Jorm
  module Config
    module_function

    LISTEN_HOST = ENV.fetch("DS_PROXY_HOST", "127.0.0.1")
    LISTEN_PORT = Integer(ENV.fetch("DS_PROXY_PORT", "8787"))

    UPSTREAM_URL = "https://api.deepseek.com"

    def record_enabled?
      %w[true 1].include?(ENV["DS_DUMP"].to_s)
    end

    def record_dir
      Pathname(ENV.fetch("DS_DUMP_DIR", "./dumps")).expand_path
    end

    def record_response?
      %w[true 1].include?(ENV["DS_DUMP_RESPONSE"].to_s)
    end

    def record_max_files
      Integer(ENV.fetch("DS_DUMP_MAX_FILES", "9"))
    end

    def record_max_age_hours
      Integer(ENV.fetch("DS_DUMP_MAX_AGE_HOURS", "0"))
    end
  end
end
