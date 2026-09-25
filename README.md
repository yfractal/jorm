# jorm

Reverse proxy (Ruby / Falcon / Async) that forwards Anthropic-compatible
requests to any configured upstream, with optional patching of Cursor
security-classifier payloads and request/response recording to
GreptimeDB (default) and/or a local dump file.

## Setup

```bash
bundle install
```

### Recording database (GreptimeDB)

Request/response recording to [GreptimeDB](https://greptime.com/) is on
by default. Start it locally with Docker Compose, then apply the schema:

```bash
docker compose up -d
bin/migrate
```

`docker compose up -d` starts a standalone GreptimeDB instance (dashboard
at `http://localhost:4000/dashboard`). `bin/migrate` creates the
`jorm` database if it doesn't exist, then applies `db/schema.sql`
(idempotent -- safe to re-run) via GreptimeDB's PostgreSQL wire
protocol (port 4003).

To wipe everything and start fresh (like Rails `db:reset`):

```bash
bin/db_reset
```

That drops `GREPTIMEDB_DATABASE` (default `jorm`), recreates it, and
re-runs `bin/migrate`. All recorded traffic in that database is lost.

If GreptimeDB isn't available, set `JO_DB_RECORD=0` to disable DB
recording instead.

## Run

```bash
bin/server
```

Listens on `http://127.0.0.1:8787` by default. Health check:

```bash
curl http://127.0.0.1:8787/health
# => {"ok":true}
```

> **macOS note:** Falcon runs multiple forked worker processes by
> default. Loading the `pg` gem's underlying `libpq` library before
> `fork()` can trip a macOS Objective-C fork-safety check, crashing
> workers with `+[__NSCFConstantString initialize]`. `bin/server`
> works around this automatically by setting
> `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` on Darwin.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `JO_UPSTREAM_URL` | *(required)* | Base URL to proxy requests to, e.g. `https://openrouter.ai/api` |
| `JO_PROXY_HOST` | `127.0.0.1` | Bind host |
| `JO_PROXY_PORT` | `8787` | Bind port |
| `JO_DB_RECORD` | on | Set to `0`/`false` to disable recording to GreptimeDB |
| `GREPTIMEDB_HOST` | `127.0.0.1` | GreptimeDB host |
| `GREPTIMEDB_PORT` | `4003` | GreptimeDB PostgreSQL wire protocol port |
| `GREPTIMEDB_DATABASE` | `jorm` | GreptimeDB database name (created by `bin/migrate` if missing) |
| `GREPTIMEDB_USER` | *(none)* | GreptimeDB user, if auth is configured |
| `GREPTIMEDB_PASSWORD` | *(none)* | GreptimeDB password, if auth is configured |
| `JO_DUMP` | off | Set to `1`/`true` to also record traffic to a local dump file |
| `JO_DUMP_DIR` | `./dumps` | Dump output directory |

DB recording and file dumping are independent and can both be on at
once. DB writes happen on a dedicated background thread (see
`Jorm::Db::Writer`), so a slow/unreachable GreptimeDB can't stall a
proxied request -- errors are logged and swallowed.

Example with dumps enabled too:

```bash
JO_DUMP=1 bin/server
```

Each server run creates a single `dump-<timestamp>.jsonl` file (one JSON
record per line) in `JO_DUMP_DIR`, and every request/response record for
that run is appended to it. `bin/server` picks the filename once (via
`JO_DUMP_FILE`) before starting the server, so Falcon's multiple worker
processes all append to that same file instead of each creating its own;
writes are file-locked to keep concurrent appends from interleaving.

Sensitive headers (`authorization`, `x-api-key`) and `sk-...` tokens in
bodies are redacted before being recorded (both to GreptimeDB and to
dump files); forwarded traffic is unchanged.

## Tests

```bash
bundle exec rspec
```
