# The Ambient protocol, version 1

A hub collects small, meaningful events from many publishers and streams them to readers. Pager Ambient is a
reader. Any server that implements this document is a hub.

A hub is addressed by one **base URL**, e.g. `https://hub.example.com/v1/events`. All paths below are relative
to it; `/` means the base URL itself, with no trailing slash. All bodies are JSON (UTF-8) unless noted. All times
are RFC 3339 UTC (`…Z`); hubs may send whole seconds or fractions, and readers accept both. Optional fields may be
`null` or absent; readers treat both the same.

## Keys

Every request except `GET /docs` carries `Authorization: Bearer <key>`.

- **Publish key**: may only `POST` events. Bound by the hub to exactly one source. The source of an event is the
  key's source. A `source` field in the body is optional: if it equals the key's source it is accepted, any other
  value gets 403 `source_mismatch`.
- **Reader key**: may list, stream, read sources and change its own dismiss state. Granted a set of sources (or
  all) by the hub's admin. Every response and stream frame is filtered to that grant. Has a stable reader
  identity: dismiss state belongs to the reader, not to the event.

A publish key used on a reader route, or the reverse, gets 403 (code `wrong_key_kind` suggested).

## Event

```json
{
  "id": "evt_8f2c1a",              // opaque, unique within the hub
  "cursor": "1734",                // opaque string; strictly increasing in hub order; used to resume
  "source": "deploys",             // slug [a-z0-9-]{2,48}
  "source_name": "Deploys",        // display label
  "source_color": "#c7ff00",       // or null
  "type": "deploy.failed",         // [a-z0-9._-]{1,48}
  "severity": "error",             // debug | info | notice | warn | error | critical
  "text": "**api** failed on `main`",  // ≤ 300 chars; inline markdown: **bold**, *italic*, `code`
  "detail": "3 of 12 containers unhealthy",  // optional, plain text, ≤ 1000 chars
  "subject": "production",         // optional short label, ≤ 80 chars
  "url": "https://…",              // optional, http(s) only
  "occurred_at": "2026-10-15T10:02:03Z",  // when it happened (publisher clock, clamped to ±7 days)
  "received_at": "2026-10-15T10:02:04Z",  // when the hub stored it
  "display": {                     // optional hints; readers may override
    "lifetime": 60,                // seconds 1..86400, or "sticky" (until dismissed)
    "layout": "split",             // split | inline
    "effect": "none",              // none | blink | flash | highlight | wave | gradient
    "target": "emphasis",          // emphasis | message
    "period": 2,                   // effect cycle, seconds 0.5..10
    "color": "#ff5f57"             // accent for emphasized text
  },
  "data": {},                      // optional object ≤ 8 KB, opaque
  "dismissed_at": null             // for THIS reader; null or absent on publish responses
}
```

Hubs reject unknown `display` keys/values and out-of-range fields with 400 and a message that says what to fix.

## Routes

### `POST /` — publish (publish key)
Body: `type`, `text` (required); `severity` (default `info`), `detail`, `subject`, `url`, `occurred_at`,
`display`, `data`, `idempotency_key` (≤ 128 chars) optional.
The hub stores the event before answering. **201** with the event. If the same source already used
`idempotency_key` within 7 days: **200** with the original event.

### `POST /batch` — publish many (publish key, optional for hubs)
`{"events":[…]}`, ≤ 100. Answers `{"events":[…]}` in order. Hubs without it answer 404.

### `GET /` — list (reader key)
Query: `source=a,b` `type=` `severity_min=` `q=` (text search) `after=<cursor>` `before=<cursor>`
`limit=` (≤ 500, default 100) `sticky=open` (only sticky events this reader hasn't dismissed).
Without `after`: newest first. With `after`: oldest first (catch-up).
Answers `{"events":[…], "next_before": "<cursor>|null", "latest_cursor": "<cursor>|null"}`.

### `GET /stream` — live (reader key), `text/event-stream`
Resume with header `Last-Event-ID: <cursor>` or `?after=<cursor>`; optional `?source=a,b`.
On resume the hub first replays events after the cursor (at most 1000; if more were missed it sends the newest 1000
preceded by one `gap` frame), then streams live. Without any cursor the stream is live only, from now; catch up
with `GET /?after=<cursor>`. Hubs should also send `state` frames, on resume, for events this reader dismissed
while away (best effort); on start, `GET /?sticky=open` is the truth for open stickies. Frames:

```
id: 1734
event: event
data: {…event…}

event: state
data: {"id":"evt_8f2c1a","dismissed_at":"2026-10-15T10:05:00Z"}

event: gap
data: {"after":"1734","skipped":2311,"resume":"4045"}

: keepalive
```
`state` frames are per reader (another client of the same reader dismissed something; `dismissed_at: null` means
restored). `gap`: `after` is the reader's cursor, `skipped` how many events were not replayed, `resume` the
cursor just before the first replayed event (fetch the skipped range with `GET /?after=…&before=…` if needed). A
keepalive comment is sent at least every 20 s. Readers should reconnect if 60 s pass with no bytes.

### `POST /{id}/dismiss` and `DELETE /{id}/dismiss` — reader state (reader key)
Sets / clears this reader's dismissal. Idempotent (a second dismiss keeps the first time). Answers at least
`{"id":…, "dismissed_at":…}` (hubs may answer the whole event) and, on a change, emits a `state` frame to that
reader's streams.

### `GET /sources` — (reader key)
A JSON array `[{"slug","name","color","last_event_at","count_24h"}, …]` limited to the grant. Hubs may add fields
(e.g. `archived`).

### `GET /info` — (either key)
```json
{"protocol":"ambient/1","name":"Albastar Citadel","key":"reader","reader":"adam-mac",
 "sources":["deploys","narkis"],"features":["batch","search"],"docs":"https://…/v1/events/docs"}
```
Clients call this when a connection is added, to validate the key and show what it can see.

### `GET /docs` — public, `text/markdown`
The publisher's guide for this hub, written for humans and coding agents: base URL, auth, one complete publish
example per common language, limits, severities, idempotency, and the rule that publishing must never block or
crash the app (≤ 3 s timeout, ≤ 3 retries with backoff, then drop).

## Errors
A JSON object with at least `code` (snake_case) and `message` (says what to fix), e.g.
`{"ok":false,"error":"rate-limited","code":"rate_limited","message":"…"}`; hubs may add fields such as `meta`.
Statuses: 401 bad/revoked key, 403 wrong kind or
source not granted, 404 unknown event, 413 too large, 429 with `Retry-After`.

## Limits (defaults; hubs may differ and must state them in `/docs`)
Body ≤ 16 KB. Publish: 120 requests/min per key, burst 30, and 300 events/min (each event in a batch counts).
Streams: 8 concurrent per reader key (the next one gets 429 `too_many_streams`).

## Changes
- 2026-10-15: aligned with the first production hub (Citadel): errors are flat `{code, message}`; `source` in the
  body tolerated when it matches the key; `gap` carries `{after, skipped, resume}`; `/sources` is a bare array;
  dismiss may answer the full event; cursor-less streams are live only.
