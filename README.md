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
| `DS_PROXY_HOST` | `127.0.0.1` | Bind host |
| `DS_PROXY_PORT` | `8787` | Bind port |
| `DS_DUMP` | off | Set to `1`/`true` to write dump JSON files |
| `DS_DUMP_DIR` | `./dumps` | Dump output directory |
| `DS_DUMP_RESPONSE` | off | Also capture upstream response bodies |
| `DS_DUMP_MAX_FILES` | `9` | Max dump files retained (`0` = unlimited) |
| `DS_DUMP_MAX_AGE_HOURS` | `0` | Max dump age in hours (`0` = unlimited) |

Example with dumps enabled:

```bash
DS_DUMP=1 DS_DUMP_RESPONSE=1 bin/server
```

Sensitive headers (`authorization`, `x-api-key`) and `sk-...` tokens in
bodies are redacted in dump files only; forwarded traffic is unchanged.

## Tests

```bash
bundle exec rspec
```
