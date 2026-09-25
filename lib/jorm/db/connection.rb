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
        with_connection { |conn| conn.exec_params(sql, params) }
      end

      private

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
