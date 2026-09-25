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
    # via PG::Connection#escape_literal -- GreptimeDB reports
    # standard_conforming_strings=on (backslashes are literal in a plain
    # '...' string), but escape_literal still emits Postgres's legacy
    # E'...' backslash-escaped form for values containing a backslash,
    # which GreptimeDB then fails to un-escape correctly, corrupting any
    # JSON value that contains a literal backslash or escaped quote.
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
        else "'#{value.to_s.gsub("'", "''")}'"
        end
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
