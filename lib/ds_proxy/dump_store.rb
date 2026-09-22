# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require "pathname"

module DsProxy
  class DumpStore
    DUMP_FILE_PATTERN = /^(req|res)-.+\.json$/

    def initialize(
      enabled: Config.dump_enabled?,
      dir: Config.dump_dir,
      dump_response: Config.dump_response?,
      max_files: Config.dump_max_files,
      max_age_hours: Config.dump_max_age_hours
    )
      @enabled = enabled
      @dir = Pathname(dir)
      @dump_response = dump_response
      @max_files = max_files
      @max_age_hours = max_age_hours

      ensure_dir! if @enabled
    end

    def enabled?
      @enabled
    end

    def dump_response?
      @dump_response
    end

    def redact_headers(headers)
      redacted = {}

      headers.each do |name, value|
        lower = name.to_s.downcase
        if lower == "x-api-key" || lower == "authorization"
          redacted[name] = "***redacted***"
        elsif !value.nil?
          redacted[name] = value
        end
      end

      redacted
    end

    def redact_body_text(text)
      text.gsub(/sk-[A-Za-z0-9_-]{6,}/, "sk-***redacted***")
    end

    def write(prefix, meta)
      return unless @enabled

      ts = Time.now.utc.iso8601(3).tr(":", "-")
      filename = "#{prefix}-#{ts}.json"
      filepath = @dir.join(filename)

      File.write(filepath, JSON.pretty_generate(meta))
      puts "  \u{1F4C4} dumped \u2192 #{filepath}"
      cleanup!
    end

    def cleanup!
      return unless @enabled

      files = Dir.children(@dir).filter_map do |name|
        next unless DUMP_FILE_PATTERN.match?(name)

        full = @dir.join(name)
        next unless full.file?

        { full: full, mtime: full.mtime.to_f }
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end

      files.sort_by! { |e| e[:mtime] }
      removed = 0

      if @max_age_hours > 0
        cutoff = Time.now.to_f - (@max_age_hours * 3600)
        while files.any? && files.first[:mtime] < cutoff
          files.shift[:full].unlink
          removed += 1
        end
      end

      if @max_files > 0
        while files.length > @max_files
          files.shift[:full].unlink
          removed += 1
        end
      end

      if removed > 0
        puts "  \u{1F9F9} dump cleanup: removed #{removed} old file(s)"
      end
    rescue StandardError
      # Cleanup failure must not affect request forwarding.
    end

    def parse_body_for_dump(raw_bytes, content_type)
      return nil if raw_bytes.nil? || raw_bytes.empty?

      raw = redact_body_text(raw_bytes.dup.force_encoding("UTF-8"))
      if content_type.to_s.include?("application/json")
        JSON.parse(raw)
      else
        raw
      end
    rescue JSON::ParserError
      raw
    end

    private

    def ensure_dir!
      FileUtils.mkdir_p(@dir) unless @dir.directory?
    end
  end
end
