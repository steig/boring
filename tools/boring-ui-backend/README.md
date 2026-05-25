# boring-ui-backend

v0 prototype of the in-container chat backend that `boring-ui` (the host-side
project picker + reverse proxy, see ARD-0021) routes to. Implements ARD-0022 §3
("in-container boring-ui backend").

**Status: v0 prototype with mocked AI events.** Real OpenCode integration is
gated on subscription verification per ARD-0020. The mock generator stands in
so the chat UI flow can be proved end-to-end before the harness lands.

## What it does

- Listens on a Unix socket inside the container (the proxy dials over it).
- Serves the chat UI (vanilla HTML/CSS/JS) at `/`.
- Streams chat events over Server-Sent Events at `/api/events`.
- Accepts user messages at `/api/messages`; with `--mock`, fires a believable
  AI turn (user_message → ai_thinking → tool_call → tool_result → turn_complete).
- Persists the thread to `/var/lib/boring-ui/threads/<slug>.jsonl` (with a temp-
  dir fallback if that location isn't writable).
- Stubs save (`/api/save`) — shells out to `boring save` if available,
  otherwise fakes a successful save so the UI flow works.

## Build

```bash
make build       # writes ./boring-ui-backend
make test        # go test ./...
make test-race   # go test -race ./...
make vet
make fmt
```

Stdlib only — no external Go dependencies.

## Run

```bash
./boring-ui-backend \
  --socket /run/boring/marketing-site.sock \
  --slug marketing-site \
  --workdir /workspaces/marketing-site \
  --mock
```

Flags:

- `--socket` (required) Unix socket path to listen on.
- `--slug` (required) project slug (matches what the proxy routes to).
- `--workdir` (required) project working directory (used by save).
- `--threads-dir` thread file directory (default `/var/lib/boring-ui/threads`).
- `--mock` use the mock AI event generator (omit for real OpenCode once wired).

The socket is chmod 0600; the proxy verifies owner UID before dialing.

## Smoke test

```bash
SOCK=$(mktemp -d)/test.sock
./boring-ui-backend --socket $SOCK --slug demo --workdir /tmp --mock &
PID=$!
sleep 0.3

# Subscribe to the SSE stream in the background.
curl -sN --unix-socket $SOCK http://./api/events &
SSE_PID=$!
sleep 0.3

# Trigger a mock turn.
curl -s --unix-socket $SOCK -X POST -H 'Content-Type: application/json' \
  -d '{"text":"hello"}' http://./api/messages

sleep 3
kill $SSE_PID $PID 2>/dev/null
```

Expected SSE output (in order):

```
event: user_message
data: {"text":"hello"}
id: evt-1

event: ai_thinking
data: {}
id: evt-2

event: tool_call
data: {"tool":"file_edit","args":{"path":"templates/hero.liquid"}}
id: evt-3

event: tool_result
data: {"tool":"file_edit","result_summary":"...","diff":"..."}
id: evt-4

event: turn_complete
data: {}
id: evt-5
```

## Integration into a preset Dockerfile (sketch — do NOT modify presets here)

The integration step lives outside this directory. The preset Dockerfile would
copy in the binary and the compose generator would launch it. Sketch only:

```dockerfile
# (sketch — preset Dockerfile additions)
COPY --from=boring-ui-backend /usr/local/bin/boring-ui-backend /usr/local/bin/
RUN mkdir -p /var/lib/boring-ui/threads && chown dev:dev /var/lib/boring-ui
```

```yaml
# (sketch — docker-compose.yml additions emitted by lib/compose.sh)
services:
  app:
    # ... existing service ...
    volumes:
      - boring-ui-state:/var/lib/boring-ui
      - boring-ui-sockets:/run/boring
    command:
      - boring-ui-backend
      - --socket=/run/boring/${SLUG}.sock
      - --slug=${SLUG}
      - --workdir=/workspaces/${SLUG}
      # --mock for v0; drop once OpenCode lands.
      - --mock

volumes:
  boring-ui-state:
  boring-ui-sockets:
```

The host-side proxy (ARD-0021) needs read access to the socket directory,
which is the integration's main wiring task — out of scope for this v0
prototype.

## Event envelope schema

Documented inline at the top of `events.go`. Summary:

| Event | Direction | Data shape |
|---|---|---|
| `user_message` | broadcast | `{text}` |
| `ai_thinking` | broadcast | `{}` |
| `tool_call` | broadcast | `{tool, args}` |
| `tool_result` | broadcast | `{tool, result_summary, diff?}` |
| `turn_complete` | broadcast | `{}` |
| `lock_status` | broadcast | `{holder, last_active}` |
| `save_started` | broadcast | `{}` |
| `save_succeeded` | broadcast | `{pr_url, branch_name}` |
| `save_failed` | broadcast | `{error, recoverable}` |

Wire format: standard SSE (`event: <type>\ndata: <json>\nid: <id>\n\n`).
Persisted form (in the JSONL thread): full envelope per line
(`{id, ts, type, data}`).

## Out of scope

- Real OpenCode wiring (gated on ARD-0020 subscription verification).
- Authentication (the proxy is the auth boundary; backend trusts the
  socket).
- Multi-user lock UX (v0 is single-user; the proxy holds the lock).
- WIP branch auto-creation / per-turn commits (assume `boring wip start`
  was called externally; not the backend's job in v0).
- Path allowlist enforcement at the tool layer (no real tool calls; the
  mock fakes everything).
- Preset Dockerfile changes (separate integration step).
