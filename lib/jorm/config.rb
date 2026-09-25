# frozen_string_literal: true

require "pathname"

module Jorm
  module Config
    module_function

    LISTEN_HOST = ENV.fetch("JO_PROXY_HOST", "127.0.0.1")
    LISTEN_PORT = Integer(ENV.fetch("JO_PROXY_PORT", "8787"))

    UPSTREAM_URL = ENV.fetch("JO_UPSTREAM_URL")

    def record_enabled?
      %w[true 1].include?(ENV["JO_DUMP"].to_s)
    end

    def record_dir
      Pathname(ENV.fetch("JO_DUMP_DIR", "./dumps")).expand_path
    end

    # Shared dump filename set once by bin/server (before it execs the
    # server) so that every worker process/fork spawned for this run
    # appends to the same file instead of each creating its own. Falls
    # back to nil, in which case Recorder generates its own filename
    # (e.g. in tests, or when running config.ru directly).
    def record_file
      ENV["JO_DUMP_FILE"]
    end

    def record_response?
      %w[true 1].include?(ENV["JO_DUMP_RESPONSE"].to_s)
    end
  end
end
