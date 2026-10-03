# frozen_string_literal: true

require "pg"

module Jorm
  module Db
    # Thin wrapper around a single PG::Connection to GreptimeDB's
    # PostgreSQL wire protocol (see docker-compose.yml / bin/migrate).
    # Only ever used from Db::Writer's dedicated background thread, so it
    # doesn't need to be thread-safe itself.
    #
    # Lazily connects on first use and transparently reconnects once if a
    # query fails due to a dropped connection (e.g. GreptimeDB restarted),
    # so a temporarily unavailable DB doesn't permanently wedge recording.
    #
    # exec_params below deliberately does NOT use PG::Connection#exec_params
    # (the extended query protocol / server-side parameter binding) --
    # GreptimeDB v1.1.4 mis-infers the type of any bound parameter that
    # targets a JSON column as "bytea" and rejects it ("\x prefix expected
    # for bytea"), even though plain literal SQL against the same column
    # works fine. Instead, +params+ are escaped client-side and
    # substituted into the "$1", "$2", ... placeholders before running
    # the query as plain text via #exec.
    #
    # String params are quoted by doubling embedded single quotes, NOT
    # via PG::Connection#escape_literal and NOT via dollar-quoting.
    # escape_literal emits Postgres's legacy E'...' form for values
    # containing a backslash, which GreptimeDB rejects on JSON columns
    # ("Unable to convert sql value E'...' to datatype Json").
    # Dollar-quoting ($tag$value$tag$) is likewise unsupported --
    # GreptimeDB fails to convert it to String/Json. Plain '...' with
    # doubled quotes keeps backslashes literal (standard_conforming_
    # strings=on), so JSON with \" or \\ survives intact.
    # NUL bytes are rewritten to \u0000 (Postgres forbids embedded NULs
    # in text), and BINARY strings are forced to UTF-8 first.
    class Connection
      def initialize(
        host: Jorm::Config.greptimedb_host,
        port: Jorm::Config.greptimedb_port,
        dbname: Jorm::Config.greptimedb_database,
        user: Jorm::Config.greptimedb_user,
        password: Jorm::Config.greptimedb_password
      )
        @host = host
        @port = port
        @dbname = dbname
        @user = user
        @password = password
        @conn = nil
      end

      def exec_params(sql, params)
        with_connection { |conn| conn.exec(interpolate(sql, params)) }
      end

      private

      def interpolate(sql, params)
        sql.gsub(/\$(\d+)/) { literal(params[Regexp.last_match(1).to_i - 1]) }
      end

      def literal(value)
        case value
        when nil then "NULL"
        when true then "TRUE"
        when false then "FALSE"
        when Integer, Float then value.to_s
        else "'#{utf8(value).gsub("\0", "\\u0000").gsub("'", "''")}'"
        end
      end

      def utf8(value)
        s = value.to_s
        s = s.dup.force_encoding("UTF-8") if s.encoding == Encoding::ASCII_8BIT
        s.valid_encoding? ? s : s.scrub
      end

      def with_connection
        yield connection
      rescue PG::ConnectionBad
        reset!
        yield connection
      end

      def connection
        @conn ||= PG.connect(host: @host, port: @port, dbname: @dbname, user: @user, password: @password)
      end

      def reset!
        @conn&.close
      rescue StandardError
        nil
      ensure
        @conn = nil
      end
    end
  end
end
