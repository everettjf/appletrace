# AppleTrace Control Protocol v1

AppleTrace uses the same control model in an embedded, non-jailbroken app and
in the `appletraced` jailbreak daemon. The protocol controls tracing; it
does not expose shell execution, arbitrary memory access, or arbitrary dylib
loading.

## Transport and authentication

- Embedded mode listens on loopback by default.
- Every HTTP and WebSocket request carries either
  `Authorization: Bearer <token>` or `X-AppleTrace-Token: <token>`.
- Browser WebSocket clients, which cannot set arbitrary request headers, send
  `appletrace-token.<token>` alongside the `appletrace-v1` subprotocol. The
  server selects only `appletrace-v1`, so the credential is not echoed.
- The default token is 128 random bits encoded as lowercase hexadecimal.
- HTTP headers are limited to 32 KiB, request bodies to 64 KiB, and paths to
  2,048 characters. Slow clients time out and the daemon bounds concurrent
  clients instead of creating unbounded workers.
- LAN binding is opt-in and should be paired with a device-local approval flow
  before it is exposed by a host app.

## HTTP API

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v1/status` | Agent, capture, hook, and buffer status |
| `POST` | `/api/v1/capture/start` | Enable recording |
| `POST` | `/api/v1/capture/stop` | Disable recording and synchronously flush |
| `POST` | `/api/v1/filters` | Replace class-prefix allow/deny filters |
| `GET` | `/api/v1/artifacts` | List trace fragments |
| `GET` | `/api/v1/artifacts/{name}` | Download one trace fragment |

The daemon adds process-scoped resources:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v1/agents` | List connected injected processes |
| `GET` | `/api/v1/agents/{id}` | Read one process snapshot |
| `POST` | `/api/v1/agents/{id}/start` | Start capture in one process |
| `POST` | `/api/v1/agents/{id}/stop` | Stop and flush one process |
| `POST` | `/api/v1/agents/{id}/flush` | Flush one process |
| `POST` | `/api/v1/agents/{id}/filters` | Replace filters in one process |
| `GET` | `/api/v1/agents/{id}/artifacts` | List one process's traces |
| `GET` | `/api/v1/agents/{id}/artifacts/{name}` | Download one process's trace |

Filter request example:

```json
{
  "allowClassPrefixes": ["MyApp", "Checkout"],
  "denyClassPrefixes": ["UIKit"]
}
```

Artifact names are restricted to one path component and are resolved only
inside `APTGetTraceDirectory()`.

## WebSocket

`GET /api/v1/stream` with a WebSocket upgrade returns an initial status frame
and then one bounded status update per second. The connection supports standard
ping/pong and close frames. Protocol v1 intentionally does not stream every
method call: full-rate events remain in AppleTrace's binary batching path.
Later revisions may add binary trace batches without changing the HTTP
resources.

The current daemon console polls the Agent list over HTTP once per second. The
WebSocket endpoint above belongs to embedded mode; a daemon event stream is
reserved for a later protocol revision.

## Agent session lifecycle

Each injected process creates one stable random `instanceId` and sends it in
the hello frame. Reconnecting with the same id replaces the stale socket while
preserving `connectionCount`; `connectionSequence` is maintained by the Agent.
The Agent sends a full status heartbeat every five seconds. `appletraced`
closes a session after 15 seconds without a complete frame and bounds command
writes to two seconds. Agent reconnects use jittered exponential backoff capped
at 30 seconds, and socket writes suppress `SIGPIPE` so a daemon restart cannot
terminate the host app. These defaults can be tightened for tests through the
environment variables documented in `Jailbreak/README.md`.

HTTP errors use a stable machine-readable code and a human-readable message:

```json
{
  "error": "invalid_filters",
  "message": "Filters must contain at most 256 short string prefixes"
}
```

Filter arrays contain at most 256 strings per list; each prefix is at most 256
characters and may not contain control characters.

## Artifact retention

The daemon applies a per-Agent quota of 256 MiB and 128 trace files. It sweeps
periodically and before artifact listings, deleting oldest fragments first
while retaining at least the newest fragment so an active capture is not
removed merely because it exceeds the quota by itself. Only regular
`.appletrace` and `.appletracebin` files participate.

## Versioning

Status responses contain `protocolVersion`. Additive fields do not change the
version. Removing fields, changing their meaning, or changing the frame format
requires a new protocol version.
