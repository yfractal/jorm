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
| `DS_DUMP` | off | Set to `1`/`true` to record traffic to a dump file |
| `DS_DUMP_DIR` | `./dumps` | Dump output directory |
| `DS_DUMP_RESPONSE` | off | Also capture upstream response bodies |

Example with dumps enabled:

```bash
DS_DUMP=1 DS_DUMP_RESPONSE=1 bin/server
```

Each server run creates a single `dump-<timestamp>.jsonl` file (one JSON
record per line) in `DS_DUMP_DIR`, and every request/response record for
that run is appended to it.

Sensitive headers (`authorization`, `x-api-key`) and `sk-...` tokens in
bodies are redacted in dump files only; forwarded traffic is unchanged.

## Tests

```bash
bundle exec rspec
```
