# DeepSeek Anthropic Proxy (Ruby / Falcon / Async)

Reverse proxy that forwards Anthropic-compatible requests to
`https://api.deepseek.com/anthropic`, with optional patching of Cursor
security-classifier payloads and request/response dump capture.

## Setup

```bash
bundle install
```

## Run

```bash
bin/server
```

Listens on `http://127.0.0.1:8787` by default. Health check:

```bash
curl http://127.0.0.1:8787/health
# => {"ok":true}
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `PROXY_HOST` | `127.0.0.1` | Bind host |
| `PROXY_PORT` | `8787` | Bind port |
| `JO_DUMP` | off | Set to `1`/`true` to record traffic to a dump file |
| `JO_DUMP_DIR` | `./dumps` | Dump output directory |
| `JO_DUMP_RESPONSE` | off | Also capture upstream response bodies |

Example with dumps enabled:

```bash
JO_DUMP=1 JO_DUMP_RESPONSE=1 bin/server
```

Each server run creates a single `dump-<timestamp>.jsonl` file (one JSON
record per line) in `JO_DUMP_DIR`, and every request/response record for
that run is appended to it. `bin/server` picks the filename once (via
`JO_DUMP_FILE`) before starting the server, so Falcon's multiple worker
processes all append to that same file instead of each creating its own;
writes are file-locked to keep concurrent appends from interleaving.

Sensitive headers (`authorization`, `x-api-key`) and `sk-...` tokens in
bodies are redacted in dump files only; forwarded traffic is unchanged.

## Tests

```bash
bundle exec rspec
```
