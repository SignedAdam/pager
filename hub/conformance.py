#!/usr/bin/env python3
"""Black-box conformance test for any Ambient protocol (ambient/1) hub.

    python3 conformance.py https://hub.example.com/v1/events \\
        --publish-key ahp_... --reader-key ahr_... \\
        [--reader-key-2 ahr_...] [--restricted-reader ahr_...]

Keys:
  --publish-key        publish key for any source S
  --reader-key         reader key granted S
  --reader-key-2       a DIFFERENT reader (another identity) also granted S: tests per-reader dismiss state
  --restricted-reader  a reader NOT granted S: tests grant filtering

The test publishes a handful of small events (type "conformance.<run>", severity debug, short lifetimes) to S and
dismisses its own sticky events at the end. Standard library only; Python 3.8+. Exit status 0 = conformant.
"""

import argparse
import http.client
import json
import os
import queue
import re
import secrets
import socket
import ssl
import sys
import threading
import time
from urllib.parse import quote, urlencode, urlsplit

RFC3339 = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$")
SEVERITIES = ["debug", "info", "notice", "warn", "error", "critical"]
EVENT_KEYS = ["id", "cursor", "source", "source_name", "source_color", "type", "severity", "text",
              "occurred_at", "received_at"]


# ---------------------------------------------------------------------------
# output

class Out:
    def __init__(self, color):
        self.color = color
        self.passed = self.failed = self.warned = self.skipped = 0
        self.failures = []

    def c(self, code, s):
        return "\033[%sm%s\033[0m" % (code, s) if self.color else s

    def section(self, name):
        print("\n" + self.c("1", name))

    def ok(self, name):
        self.passed += 1
        print("  %s %s" % (self.c("32", "✓"), name))

    def fail(self, name, why):
        self.failed += 1
        self.failures.append((name, why))
        print("  %s %s\n      %s" % (self.c("31", "✗"), name, self.c("31", why)))

    def warn(self, name, why):
        self.warned += 1
        print("  %s %s\n      %s" % (self.c("33", "!"), name, self.c("33", why)))

    def skip(self, name, why):
        self.skipped += 1
        print("  %s %s %s" % (self.c("90", "-"), self.c("90", name), self.c("90", "(skipped: %s)" % why)))


class Fail(Exception):
    pass


def expect(cond, why):
    if not cond:
        raise Fail(why)


# ---------------------------------------------------------------------------
# HTTP

class Resp:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers
        self.body = body
        try:
            self.json = json.loads(body.decode("utf-8")) if body else None
        except ValueError:
            self.json = None

    def header(self, name):
        for k, v in self.headers:
            if k.lower() == name.lower():
                return v
        return None

    def short(self):
        b = self.body.decode("utf-8", "replace")
        return "HTTP %d %s" % (self.status, b[:300] + ("…" if len(b) > 300 else ""))


class Client:
    def __init__(self, base, insecure=False, timeout=15):
        self.base = base.rstrip("/")
        u = urlsplit(self.base)
        if u.scheme not in ("http", "https"):
            raise SystemExit("base URL must be http(s)://…")
        self.https = u.scheme == "https"
        self.host = u.hostname
        self.port = u.port or (443 if self.https else 80)
        self.path = u.path.rstrip("/")
        self.timeout = timeout
        self.ctx = ssl._create_unverified_context() if insecure else ssl.create_default_context()

    def connect(self, timeout=None):
        t = timeout or self.timeout
        if self.https:
            return http.client.HTTPSConnection(self.host, self.port, timeout=t, context=self.ctx)
        return http.client.HTTPConnection(self.host, self.port, timeout=t)

    def url(self, rel, params=None):
        # "/" in the protocol means the base URL itself: no trailing slash.
        p = self.path + ("" if rel == "/" else rel)
        if params:
            p += "?" + urlencode(params)
        return p

    def req(self, method, rel, key=None, body=None, raw=None, params=None, headers=None):
        h = {"Accept": "application/json"}
        if key:
            h["Authorization"] = "Bearer " + key
        data = raw
        if body is not None:
            data = json.dumps(body).encode("utf-8")
        if data is not None:
            h["Content-Type"] = "application/json"
        h.update(headers or {})
        conn = self.connect()
        try:
            conn.request(method, self.url(rel, params), body=data, headers=h)
            r = conn.getresponse()
            return Resp(r.status, r.getheaders(), r.read())
        finally:
            conn.close()


class SSE:
    """Minimal EventSource: collects frames on a background thread."""

    def __init__(self, client, key, params=None, last_event_id=None):
        self.frames = queue.Queue()
        self.status = None
        self.headers = []
        self.error = None
        self.sock = None
        self.conn = client.connect(timeout=90)
        h = {"Accept": "text/event-stream", "Authorization": "Bearer " + key, "Cache-Control": "no-cache"}
        if last_event_id is not None:
            h["Last-Event-ID"] = last_event_id
        self.conn.request("GET", client.url("/stream", params), headers=h)
        self.sock = self.conn.sock
        self.resp = self.conn.getresponse()
        self.status = self.resp.status
        self.headers = self.resp.getheaders()
        if self.status == 200:
            self.thread = threading.Thread(target=self.read, daemon=True)
            self.thread.start()
        else:
            self.body = self.resp.read()
            self.close()

    def header(self, name):
        for k, v in self.headers:
            if k.lower() == name.lower():
                return v
        return None

    def read(self):
        ev = {"event": "message", "id": None, "data": []}
        try:
            while True:
                line = self.resp.readline()
                if not line:
                    break
                line = line.decode("utf-8").rstrip("\r\n")
                if line == "":
                    if ev["data"]:
                        data = "\n".join(ev["data"])
                        try:
                            parsed = json.loads(data)
                        except ValueError:
                            parsed = None
                        self.frames.put({"event": ev["event"], "id": ev["id"], "data": parsed, "raw": data})
                    ev = {"event": "message", "id": None, "data": []}
                    continue
                if line.startswith(":"):
                    self.frames.put({"event": ":comment", "id": None, "data": None, "raw": line[1:].strip()})
                    continue
                field, _, value = line.partition(":")
                if value.startswith(" "):
                    value = value[1:]
                if field == "event":
                    ev["event"] = value
                elif field == "id":
                    ev["id"] = value
                elif field == "data":
                    ev["data"].append(value)
        except Exception as e:
            self.error = e
        self.frames.put({"event": ":closed", "id": None, "data": None, "raw": ""})

    def next(self, pred, timeout):
        """First frame matching pred within timeout, else None. Skips comments."""
        end = time.time() + timeout
        while True:
            left = end - time.time()
            if left <= 0:
                return None
            try:
                f = self.frames.get(timeout=left)
            except queue.Empty:
                return None
            if f["event"] == ":closed":
                self.frames.put(f)
                return None
            if pred(f):
                return f

    def collect(self, seconds):
        """All non-comment frames that arrive within `seconds`."""
        out, end = [], time.time() + seconds
        while True:
            left = end - time.time()
            if left <= 0:
                return out
            try:
                f = self.frames.get(timeout=left)
            except queue.Empty:
                return out
            if f["event"] == ":closed":
                self.frames.put(f)
                return out
            if not f["event"].startswith(":"):
                out.append(f)

    def close(self):
        try:
            if self.sock is not None:
                self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.conn.close()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# checks

def is_error_shape(r, status, code=None):
    if r.status != status:
        return "expected HTTP %d, got %s" % (status, r.short())
    e = r.json if isinstance(r.json, dict) else None
    if not e or not isinstance(e.get("code"), str) or not isinstance(e.get("message"), str):
        return "expected {\"code\",\"message\"}, got %s" % r.short()
    if code and e["code"] != code:
        return "expected error code %r, got %r (%s)" % (code, e["code"], e["message"])
    return None


def check_event(ev, reader_side):
    expect(isinstance(ev, dict), "event is not an object: %r" % (ev,))
    for k in EVENT_KEYS:
        expect(k in ev, "event lacks %r: %s" % (k, json.dumps(ev)[:300]))
    expect(isinstance(ev["id"], str) and ev["id"], "id must be a non-empty string")
    expect(isinstance(ev["cursor"], str) and ev["cursor"], "cursor must be a non-empty string, got %r" % (ev["cursor"],))
    expect(ev["severity"] in SEVERITIES, "bad severity %r" % ev["severity"])
    for k in ("occurred_at", "received_at"):
        expect(isinstance(ev[k], str) and RFC3339.match(ev[k]), "%s is not RFC 3339: %r" % (k, ev[k]))
    if reader_side:
        expect("dismissed_at" in ev, "reader-side event lacks dismissed_at")
    else:
        expect(ev.get("dismissed_at") is None, "publish response must not carry a dismissal")


class Run:
    def __init__(self, a, out):
        self.a = a
        self.out = out
        self.cl = Client(a.base_url, insecure=a.insecure)
        self.run = secrets.token_hex(3)
        self.type = "conformance.r" + self.run
        self.source = None
        self.reader = None
        self.features = []
        self.streams = []
        self.sticky_ids = []
        self.n = 0

    def check(self, name, fn, *args):
        try:
            fn(*args)
            self.out.ok(name)
            return True
        except Fail as e:
            self.out.fail(name, str(e))
        except (OSError, http.client.HTTPException) as e:
            self.out.fail(name, "connection error: %r" % e)
        return False

    def publish(self, text=None, **fields):
        self.n += 1
        body = {"type": self.type, "text": text or "conformance %s #%d" % (self.run, self.n),
                "severity": "debug", "display": {"lifetime": 5}}
        body.update(fields)
        r = self.cl.req("POST", "/", self.a.publish_key, body=body)
        if r.status == 429:
            time.sleep(float(r.header("Retry-After") or 2))
            r = self.cl.req("POST", "/", self.a.publish_key, body=body)
        expect(r.status == 201, "publish: expected 201, got %s" % r.short())
        return r.json

    def list(self, key, **params):
        return self.cl.req("GET", "/", key, params=params)

    def mine(self, key, **params):
        params.setdefault("type", self.type)
        r = self.list(key, **params)
        expect(r.status == 200, "list: %s" % r.short())
        expect(isinstance(r.json, dict) and isinstance(r.json.get("events"), list), "list: no events array")
        return r.json

    def stream(self, key, params=None, last_event_id=None):
        s = SSE(self.cl, key, params, last_event_id)
        self.streams.append(s)
        return s

    def opened(self, s):
        expect(s.status == 200, "stream: expected 200, got HTTP %s %s" % (s.status, getattr(s, "body", b"")[:200]))
        ct = (s.header("Content-Type") or "").split(";")[0].strip()
        expect(ct == "text/event-stream", "stream Content-Type is %r" % ct)
        time.sleep(0.4)  # let the hub register the stream before we publish

    # -- sections ----------------------------------------------------------

    def docs(self):
        self.out.section("docs")
        r = self.cl.req("GET", "/docs")
        def public():
            expect(r.status == 200, "GET /docs without a key: %s" % r.short())
            ct = (r.header("Content-Type") or "").split(";")[0].strip()
            expect(ct == "text/markdown", "Content-Type is %r, want text/markdown" % ct)
        self.check("GET /docs is public text/markdown", public)
        text = r.body.decode("utf-8", "replace")
        def content():
            low = text.lower()
            for needle in ("authorization", "bearer", "idempotency_key", "severity", "critical"):
                expect(needle in low, "docs never mention %r" % needle)
            expect(re.search(r"\b3 ?s|3 seconds|timeout", low), "docs do not state the ≤ 3 s timeout rule")
            expect("retr" in low, "docs do not state the retry rule")
        self.check("docs cover auth, severities, idempotency, timeout and retry rule", content)
        if self.cl.base in text:
            self.out.ok("docs use this hub's base URL")
        else:
            self.out.warn("docs use this hub's base URL",
                          "%s does not appear in /docs (fine behind some proxies; check --public-url)" % self.cl.base)

    def auth(self):
        self.out.section("keys and auth")
        r = self.cl.req("GET", "/info")
        self.check("no key → 401 error", lambda: expect(not is_error_shape(r, 401), is_error_shape(r, 401)))
        r = self.cl.req("GET", "/info", "ahr_" + "x" * 32)
        self.check("unknown key → 401 error", lambda: expect(not is_error_shape(r, 401), is_error_shape(r, 401)))

        r = self.cl.req("GET", "/info", self.a.publish_key)
        def pinfo():
            expect(r.status == 200 and isinstance(r.json, dict), "GET /info with publish key: %s" % r.short())
            j = r.json
            expect(j.get("protocol") == "ambient/1", "protocol is %r" % j.get("protocol"))
            expect(j.get("key") == "publish", "key is %r, want \"publish\"" % j.get("key"))
            src = j.get("sources")
            expect(isinstance(src, list) and len(src) == 1, "a publish key must list exactly its one source: %r" % src)
            self.source = src[0]
        self.check("GET /info with publish key: protocol ambient/1, key publish, one source", pinfo)

        r = self.cl.req("GET", "/info", self.a.reader_key)
        def rinfo():
            expect(r.status == 200 and isinstance(r.json, dict), "GET /info with reader key: %s" % r.short())
            j = r.json
            expect(j.get("protocol") == "ambient/1", "protocol is %r" % j.get("protocol"))
            expect(j.get("key") == "reader", "key is %r" % j.get("key"))
            expect(isinstance(j.get("reader"), str) and j["reader"], "reader identity missing")
            expect(isinstance(j.get("name"), str), "name missing")
            expect(isinstance(j.get("features"), list), "features must be a list")
            expect(isinstance(j.get("docs"), str) and j["docs"].endswith("/docs"), "docs URL missing: %r" % j.get("docs"))
            expect(isinstance(j.get("sources"), list), "sources must be a list")
            self.reader = j["reader"]
            self.features = j["features"]
            expect(self.source in j["sources"],
                   "the reader key must be granted the publish key's source %r; it sees %r" % (self.source, j["sources"]))
        self.check("GET /info with reader key: reader, name, sources, features, docs", rinfo)

        r = self.list(self.a.publish_key)
        self.check("publish key on GET / → 403",
                   lambda: expect(not is_error_shape(r, 403), is_error_shape(r, 403)))
        r = self.cl.req("POST", "/", self.a.reader_key, body={"type": self.type, "text": "x"})
        self.check("reader key on POST / → 403",
                   lambda: expect(not is_error_shape(r, 403), is_error_shape(r, 403)))
        s = SSE(self.cl, self.a.publish_key)
        def pk_stream():
            expect(s.status == 403, "publish key on /stream: expected 403, got %s" % s.status)
        self.check("publish key on GET /stream → 403", pk_stream)

    def publish_section(self):
        self.out.section("publish")
        state = {}
        def minimal():
            r = self.cl.req("POST", "/", self.a.publish_key, body={"type": self.type, "text": "conformance %s minimal" % self.run})
            expect(r.status == 201, "expected 201, got %s" % r.short())
            check_event(r.json, reader_side=False)
            j = r.json
            expect(j["source"] == self.source, "source is %r, want the key's source %r" % (j["source"], self.source))
            expect(j["severity"] == "info", "default severity must be info, got %r" % j["severity"])
            expect(j["type"] == self.type, "type not echoed")
            state["first"] = j
        self.check("minimal event → 201 with the stored event", minimal)

        def full():
            body = {"type": self.type, "text": "**conformance** *%s* `full`" % self.run, "severity": "warn",
                    "detail": "detail text", "subject": "conformance", "url": "https://example.com/x",
                    "occurred_at": "2020-01-01T00:00:00Z",
                    "display": {"lifetime": 5, "layout": "inline", "effect": "highlight", "target": "message",
                                "period": 1.5, "color": "#ff5f57"},
                    "data": {"run": self.run, "n": 1}}
            r = self.cl.req("POST", "/", self.a.publish_key, body=body)
            expect(r.status == 201, "expected 201, got %s" % r.short())
            j = r.json
            check_event(j, reader_side=False)
            for k in ("text", "detail", "subject", "url", "severity"):
                expect(j.get(k) == body[k], "%s not stored as sent: %r" % (k, j.get(k)))
            expect(j.get("data") == body["data"], "data not stored as sent")
            expect(isinstance(j.get("display"), dict) and j["display"].get("effect") == "highlight", "display not stored")
            expect(not j["occurred_at"].startswith("2020"), "occurred_at 2020 must be clamped to ±7 days, got %s" % j["occurred_at"])
        self.check("all fields round-trip; occurred_at is clamped to ±7 days", full)

        def idem():
            key = "conf-%s-idem" % self.run
            a = self.cl.req("POST", "/", self.a.publish_key, body={"type": self.type, "text": "idem", "idempotency_key": key})
            b = self.cl.req("POST", "/", self.a.publish_key, body={"type": self.type, "text": "idem again", "idempotency_key": key})
            expect(a.status == 201, "first: expected 201, got %s" % a.short())
            expect(b.status == 200, "repeat: expected 200, got %s" % b.short())
            expect(a.json["id"] == b.json["id"] and a.json["cursor"] == b.json["cursor"], "repeat must return the original event")
            expect(b.json["text"] == "idem", "repeat must return the ORIGINAL event, not the new body")
        self.check("same idempotency_key → 200 with the original event", idem)

        cases = [
            ("missing type", {"text": "x"}, None),
            ("missing text", {"type": self.type}, None),
            ("empty text", {"type": self.type, "text": ""}, None),
            ("text over 300 characters", {"type": self.type, "text": "x" * 301}, None),
            ("bad type characters", {"type": "Deploy Failed", "text": "x"}, None),
            ("unknown severity", {"type": self.type, "text": "x", "severity": "fatal"}, None),
            ("detail over 1000 characters", {"type": self.type, "text": "x", "detail": "d" * 1001}, None),
            ("subject over 80 characters", {"type": self.type, "text": "x", "subject": "s" * 81}, None),
            ("non-http url", {"type": self.type, "text": "x", "url": "javascript:alert(1)"}, None),
            ("bad occurred_at", {"type": self.type, "text": "x", "occurred_at": "yesterday"}, None),
            ("unknown display key", {"type": self.type, "text": "x", "display": {"sound": "beep"}}, None),
            ("display.lifetime 0", {"type": self.type, "text": "x", "display": {"lifetime": 0}}, None),
            ("display.effect unknown", {"type": self.type, "text": "x", "display": {"effect": "spin"}}, None),
            ("display.period 20", {"type": self.type, "text": "x", "display": {"period": 20}}, None),
            ("data not an object", {"type": self.type, "text": "x", "data": [1, 2]}, None),
            ("idempotency_key over 128", {"type": self.type, "text": "x", "idempotency_key": "k" * 129}, None),
        ]
        def validation():
            bad = []
            for name, body, code in cases:
                r = self.cl.req("POST", "/", self.a.publish_key, body=body)
                err = is_error_shape(r, 400, code)
                if err:
                    bad.append("%s: %s" % (name, err))
            expect(not bad, "; ".join(bad))
        self.check("invalid events → 400 with a message (%d cases)" % len(cases), validation)

        def source_field():
            r = self.cl.req("POST", "/", self.a.publish_key, body={"type": self.type, "text": "x", "source": "zz-not-mine"})
            err = is_error_shape(r, 403, "source_mismatch")
            expect(not err, "another source in the body: %s" % err)
            r = self.cl.req("POST", "/", self.a.publish_key,
                            body={"type": self.type, "text": "own source %s" % self.run, "source": self.source,
                                  "severity": "debug", "display": {"lifetime": 1}})
            expect(r.status == 201, "the key's own source in the body must be accepted: %s" % r.short())
        self.check("source in body: own source accepted, another → 403 source_mismatch", source_field)

        def invalid_json():
            r = self.cl.req("POST", "/", self.a.publish_key, raw=b"{not json")
            err = is_error_shape(r, 400)
            expect(not err, err)
        self.check("invalid JSON → 400", invalid_json)

        def too_large():
            r = self.cl.req("POST", "/", self.a.publish_key,
                            body={"type": self.type, "text": "x", "data": {"pad": "p" * (64 * 1024)}})
            err = is_error_shape(r, 413)
            expect(not err, err)
        self.check("64 KB body → 413", too_large)

    def batch(self):
        self.out.section("batch")
        body = {"events": [{"type": self.type, "text": "batch %s a" % self.run, "severity": "debug"},
                           {"type": self.type, "text": "batch %s b" % self.run, "severity": "debug"}]}
        r = self.cl.req("POST", "/batch", self.a.publish_key, body=body)
        if r.status == 404:
            self.out.skip("POST /batch", "hub answers 404 (batch is optional)")
            return
        def ok():
            expect(r.status in (200, 201), "expected 201, got %s" % r.short())
            evs = (r.json or {}).get("events")
            expect(isinstance(evs, list) and len(evs) == 2, "expected {\"events\":[2 events]}")
            expect([e["text"] for e in evs] == ["batch %s a" % self.run, "batch %s b" % self.run], "events not in order")
            for e in evs:
                check_event(e, reader_side=False)
        self.check("POST /batch stores events and answers them in order", ok)
        r2 = self.cl.req("POST", "/batch", self.a.publish_key,
                         body={"events": [{"type": self.type, "text": "ok"}, {"type": self.type}]})
        self.check("POST /batch with one invalid event → 400",
                   lambda: expect(not is_error_shape(r2, 400), is_error_shape(r2, 400)))

    def listing(self):
        self.out.section("list")
        start = self.mine(self.a.reader_key, limit=1)
        evs = [self.publish("list %s %s" % (self.run, x), severity=sev)
               for x, sev in (("a", "debug"), ("b", "warn"), ("c", "error"))]
        ids = [e["id"] for e in evs]

        def newest_first():
            j = self.mine(self.a.reader_key, limit=500)
            got = [e["id"] for e in j["events"] if e["id"] in ids]
            expect(got == ids[::-1], "without after: expected newest first %s, got %s" % (ids[::-1], got))
            for e in j["events"]:
                check_event(e, reader_side=True)
            expect("next_before" in j and "latest_cursor" in j, "answer lacks next_before / latest_cursor")
            expect(isinstance(j["latest_cursor"], str), "latest_cursor must be a cursor string")
        self.check("GET / is newest first; events carry dismissed_at; latest_cursor set", newest_first)

        def after():
            j = self.mine(self.a.reader_key, after=evs[0]["cursor"])
            got = [e["id"] for e in j["events"]]
            expect(got[:2] == ids[1:], "after=<cursor of a>: expected oldest first [b, c], got %s" % got)
            j = self.mine(self.a.reader_key, after=evs[2]["cursor"])
            expect([e for e in j["events"] if e["id"] in ids] == [], "after=<cursor of c> must not include a, b, c")
        self.check("after=<cursor> answers oldest first, strictly after the cursor", after)

        def paging():
            j = self.mine(self.a.reader_key, limit=2)
            expect(len(j["events"]) == 2, "limit=2 gave %d events" % len(j["events"]))
            nb = j.get("next_before")
            expect(isinstance(nb, str), "next_before must be a cursor when more events exist, got %r" % (nb,))
            j2 = self.mine(self.a.reader_key, limit=2, before=nb)
            first = {e["id"] for e in j["events"]}
            expect(j2["events"] and not first & {e["id"] for e in j2["events"]}, "before=next_before repeated events")
            expect(j2["events"][0]["id"] == ids[0] or ids[0] not in first,
                   "before=next_before did not continue with the next older event")
        self.check("limit and before=next_before page backwards", paging)

        def filters():
            j = self.mine(self.a.reader_key, severity_min="warn")
            got = {e["id"] for e in j["events"]}
            expect(ids[1] in got and ids[2] in got and ids[0] not in got, "severity_min=warn wrong: %s" % got)
            j = self.mine(self.a.reader_key, source=self.source)
            expect(all(e["source"] == self.source for e in j["events"]) and ids[0] in {e["id"] for e in j["events"]},
                   "source=%s filter wrong" % self.source)
            j = self.mine(self.a.reader_key, type="conformance.nothing-here")
            expect(j["events"] == [], "type filter wrong")
        self.check("filters: severity_min, source, type", filters)

        if "search" in self.features:
            def search():
                j = self.mine(self.a.reader_key, q="list %s b" % self.run)
                expect([e["id"] for e in j["events"]] == [ids[1]], "q= should find exactly event b, got %s"
                       % [e["text"] for e in j["events"]])
            self.check("q= text search", search)
        else:
            self.out.skip("q= text search", "hub does not list feature \"search\"")

        def bad_limit():
            r = self.list(self.a.reader_key, limit="5000")
            expect(r.status in (200, 400), "limit=5000: %s" % r.short())
            if r.status == 200:
                expect(len(r.json["events"]) <= 500, "limit must be capped at 500")
        self.check("limit over 500 is rejected or capped", bad_limit)

    def sources(self):
        self.out.section("sources")
        r = self.cl.req("GET", "/sources", self.a.reader_key)
        def ok():
            expect(r.status == 200, r.short())
            srcs = r.json
            expect(isinstance(srcs, list), "expected a JSON array of sources")
            mine = [s for s in srcs if s.get("slug") == self.source]
            expect(mine, "source %r missing" % self.source)
            s = mine[0]
            for k in ("slug", "name", "color", "last_event_at", "count_24h"):
                expect(k in s, "source lacks %r" % k)
            expect(isinstance(s["count_24h"], int) and s["count_24h"] >= 1, "count_24h should count our events")
            expect(isinstance(s["last_event_at"], str) and RFC3339.match(s["last_event_at"]), "last_event_at not RFC 3339")
        self.check("GET /sources lists the granted source with all fields", ok)
        r2 = self.cl.req("GET", "/sources", self.a.publish_key)
        self.check("publish key on /sources → 403",
                   lambda: expect(not is_error_shape(r2, 403), is_error_shape(r2, 403)))

    def dismiss(self):
        self.out.section("dismiss and sticky")
        R, R2 = self.a.reader_key, self.a.reader_key_2
        ev = self.publish("sticky %s" % self.run, display={"lifetime": "sticky"})
        self.sticky_ids.append(ev["id"])

        def open_list():
            j = self.mine(R, sticky="open")
            expect(ev["id"] in {e["id"] for e in j["events"]}, "new sticky event missing from sticky=open")
            expect(all((e.get("display") or {}).get("lifetime") == "sticky" for e in j["events"]),
                   "sticky=open returned non-sticky events")
        self.check("sticky=open lists the undismissed sticky event", open_list)

        def do_dismiss():
            r = self.cl.req("POST", "/%s/dismiss" % quote(ev["id"]), R)
            expect(r.status == 200, r.short())
            expect(r.json.get("id") == ev["id"] and isinstance(r.json.get("dismissed_at"), str)
                   and RFC3339.match(r.json["dismissed_at"]), "expected {id, dismissed_at}: %s" % r.short())
            again = self.cl.req("POST", "/%s/dismiss" % quote(ev["id"]), R)
            expect(again.status == 200, "repeat dismiss: %s" % again.short())
            j = self.mine(R, sticky="open")
            expect(ev["id"] not in {e["id"] for e in j["events"]}, "dismissed event still in sticky=open")
            j = self.mine(R)
            got = [e for e in j["events"] if e["id"] == ev["id"]]
            expect(got and got[0]["dismissed_at"], "list must show dismissed_at for this reader")
        self.check("POST /{id}/dismiss: idempotent; hides from sticky=open; dismissed_at in list", do_dismiss)

        if R2:
            def isolation():
                j = self.mine(R2, sticky="open")
                expect(ev["id"] in {e["id"] for e in j["events"]}, "reader 2 lost the event: dismiss state leaked across readers")
                j = self.mine(R2)
                got = [e for e in j["events"] if e["id"] == ev["id"]]
                expect(got and got[0]["dismissed_at"] is None, "reader 2 sees dismissed_at from reader 1")
            self.check("dismiss is per reader: reader 2 still has it open", isolation)
        else:
            self.out.skip("dismiss is per reader", "needs --reader-key-2")

        def restore():
            r = self.cl.req("DELETE", "/%s/dismiss" % quote(ev["id"]), R)
            expect(r.status == 200 and r.json.get("dismissed_at") is None, "DELETE: %s" % r.short())
            again = self.cl.req("DELETE", "/%s/dismiss" % quote(ev["id"]), R)
            expect(again.status == 200, "repeat DELETE: %s" % again.short())
            j = self.mine(R, sticky="open")
            expect(ev["id"] in {e["id"] for e in j["events"]}, "restored event missing from sticky=open")
        self.check("DELETE /{id}/dismiss restores it (idempotent)", restore)

        r = self.cl.req("POST", "/evt_doesnotexist0000/dismiss", R)
        self.check("dismiss unknown id → 404", lambda: expect(not is_error_shape(r, 404), is_error_shape(r, 404)))
        r = self.cl.req("POST", "/%s/dismiss" % quote(ev["id"]), self.a.publish_key)
        self.check("publish key on dismiss → 403",
                   lambda: expect(not is_error_shape(r, 403), is_error_shape(r, 403)))

    def streaming(self):
        self.out.section("stream")
        R, R2 = self.a.reader_key, self.a.reader_key_2
        live = self.stream(R, {"source": self.source})
        if not self.check("GET /stream opens text/event-stream", self.opened, live):
            return
        state = {}

        def live_event():
            ev = self.publish("live %s" % self.run)
            f = live.next(lambda f: f["event"] == "event" and (f["data"] or {}).get("id") == ev["id"], 5)
            expect(f is not None, "published event did not arrive on the stream within 5 s")
            expect(f["id"] == ev["cursor"], "SSE id must equal the event cursor (%r != %r)" % (f["id"], ev["cursor"]))
            check_event(f["data"], reader_side=True)
            state["ev"] = ev
        self.check("live event arrives as `event` frame with id = cursor", live_event)

        def resume_header():
            base = self.mine(R, limit=1)["events"]
            expect(base, "no events to resume from")
            a = self.publish("resume %s a" % self.run)
            b = self.publish("resume %s b" % self.run)
            s = self.stream(R, {"source": self.source}, last_event_id=base[0]["cursor"])
            expect(s.status == 200, "stream with Last-Event-ID: HTTP %s" % s.status)
            got = []
            while True:
                f = s.next(lambda f: f["event"] == "event", 3)
                if f is None:
                    break
                got.append(f["data"]["id"])
                if b["id"] in got:
                    break
            expect(got[-2:] == [a["id"], b["id"]] if len(got) >= 2 else False,
                   "replay after Last-Event-ID should end with [a, b] in order, got %s" % got)
            c = self.publish("resume %s c" % self.run)
            f = s.next(lambda f: f["event"] == "event" and f["data"]["id"] == c["id"], 5)
            expect(f is not None, "after replay the stream must continue live")
            s.close()
        self.check("Last-Event-ID replays missed events in order, then goes live", resume_header)

        def resume_param():
            a = state.get("ev") or self.publish("p %s" % self.run)
            b = self.publish("resume-param %s" % self.run)
            s = self.stream(R, {"after": a["cursor"], "source": self.source})
            expect(s.status == 200, "stream ?after: HTTP %s" % s.status)
            f = s.next(lambda f: f["event"] == "event", 5)
            expect(f is not None, "nothing replayed for ?after=")
            ids = [f["data"]["id"]]
            expect(a["id"] not in ids, "?after=<cursor> must not replay the cursor's own event")
            more = [x["data"]["id"] for x in s.collect(1.0) if x["event"] == "event"]
            expect(b["id"] in ids + more, "?after did not replay the missed event")
            s.close()
        self.check("?after=<cursor> replays strictly after the cursor", resume_param)

        def state_frames():
            ev = self.publish("state %s" % self.run, display={"lifetime": "sticky"})
            self.sticky_ids.append(ev["id"])
            other = self.stream(R, {"source": self.source})
            self.opened(other)
            peer = self.stream(R2, {"source": self.source}) if R2 else None
            if peer:
                self.opened(peer)
            r = self.cl.req("POST", "/%s/dismiss" % quote(ev["id"]), R)
            expect(r.status == 200, "dismiss: %s" % r.short())
            for s, name in ((live, "first"), (other, "second")):
                f = s.next(lambda f: f["event"] == "state" and (f["data"] or {}).get("id") == ev["id"], 5)
                expect(f is not None, "no `state` frame on this reader's %s stream" % name)
                expect(f["data"].get("dismissed_at") == r.json["dismissed_at"], "state frame dismissed_at mismatch")
            if peer:
                leaked = [f for f in peer.collect(1.5) if f["event"] == "state"]
                expect(not leaked, "reader 2 received reader 1's state frame: %s" % (leaked[0]["raw"] if leaked else ""))
            r = self.cl.req("DELETE", "/%s/dismiss" % quote(ev["id"]), R)
            f = live.next(lambda f: f["event"] == "state" and (f["data"] or {}).get("id") == ev["id"], 5)
            expect(f is not None and f["data"].get("dismissed_at") is None, "restore must send state with dismissed_at null")
            self.cl.req("POST", "/%s/dismiss" % quote(ev["id"]), R)
            other.close()
            if peer:
                peer.close()
        name = "state frames reach all of this reader's streams" + (", not other readers'" if R2 else "")
        self.check(name, state_frames)

        # keepalive cadence (≤ 20 s) is checked only with --slow
        if self.a.slow:
            def ka():
                s = self.stream(R, {"source": self.source})
                expect(s.status == 200, "stream: HTTP %s" % s.status)
                t0 = time.time()
                f = s.next(lambda f: f["event"] == ":comment" and f["raw"] != "" and time.time() - t0 > 0.5, 21)
                expect(f is not None, "no comment/keepalive within 21 s")
                s.close()
            self.check("keepalive comment within 20 s", ka)
        else:
            self.out.skip("keepalive comment within 20 s", "use --slow")

    def grants(self):
        self.out.section("grants")
        R3 = self.a.restricted_reader
        if not R3:
            self.out.skip("grant filtering", "needs --restricted-reader (a reader NOT granted %r)" % self.source)
            return
        r = self.cl.req("GET", "/info", R3)
        def info():
            expect(r.status == 200, r.short())
            expect(self.source not in r.json.get("sources", []),
                   "restricted reader's /info lists %r; it must not be granted it" % self.source)
        if not self.check("restricted reader's /info does not list the source", info):
            return
        s3 = self.stream(R3)
        sR = self.stream(self.a.reader_key, {"source": self.source})
        self.check("restricted reader can open a stream", self.opened, s3)
        sR.status == 200 and time.sleep(0.2)
        ev = self.publish("grant %s" % self.run)
        def stream_filter():
            expect(sR.next(lambda f: f["event"] == "event" and f["data"]["id"] == ev["id"], 5) is not None,
                   "granted reader did not get the event (control)")
            leaked = [f for f in s3.collect(1.5) if f["event"] == "event" and f["data"]["source"] == self.source]
            expect(not leaked, "restricted reader received an event from %r on its stream" % self.source)
        self.check("stream fan-out is filtered by grant", stream_filter)
        def list_filter():
            j = self.mine(R3, limit=500)
            expect(not [e for e in j["events"] if e["source"] == self.source], "restricted reader can list the source's events")
        self.check("list is filtered by grant", list_filter)
        def resume_filter():
            s = self.stream(R3, None, last_event_id="0")
            expect(s.status == 200, "stream: HTTP %s" % s.status)
            leaked = [f for f in s.collect(2.0) if f["event"] == "event" and f["data"]["source"] == self.source]
            expect(not leaked, "replay leaked an event from %r" % self.source)
            s.close()
        self.check("replay is filtered by grant", resume_filter)
        r1 = self.list(R3, source=self.source)
        self.check("?source=<not granted> on list → 403",
                   lambda: expect(not is_error_shape(r1, 403), is_error_shape(r1, 403)))
        s = SSE(self.cl, R3, {"source": self.source})
        self.check("?source=<not granted> on stream → 403", lambda: expect(s.status == 403, "got HTTP %s" % s.status))
        r2 = self.cl.req("POST", "/%s/dismiss" % quote(ev["id"]), R3)
        self.check("dismissing a not-granted event → 403 or 404",
                   lambda: expect(r2.status in (403, 404) and not is_error_shape(r2, r2.status), r2.short()))
        r3 = self.cl.req("GET", "/sources", R3)
        self.check("/sources omits the not-granted source",
                   lambda: expect(r3.status == 200 and isinstance(r3.json, list) and self.source not in [x.get("slug") for x in r3.json], r3.short()))
        s3.close()
        sR.close()

    def limits(self):
        self.out.section("limits")
        for s in self.streams:  # start from zero open streams on this key
            s.close()
        time.sleep(2.0)
        opened, refused = [], None
        try:
            for i in range(20):
                s = SSE(self.cl, self.a.reader_key, {"source": self.source})
                if s.status == 200:
                    opened.append(s)
                    continue
                refused = s
                break
        finally:
            for s in opened:
                s.close()
        if refused is None:
            self.out.warn("concurrent streams per reader key are limited", "20 streams opened; the default limit is 8")
        else:
            body = Resp(refused.status, refused.headers, getattr(refused, "body", b""))
            def shape():
                err = is_error_shape(body, 429)
                expect(not err, err)
            self.check("stream #%d of one reader key → 429 error" % (len(opened) + 1), shape)
            if len(opened) != 8:
                self.out.warn("stream limit is the default 8",
                              "%d streams were allowed (other clients of this key count too; a different limit "
                              "is allowed if /docs states it)" % len(opened))
        time.sleep(0.5)

        if not self.a.check_rate_limit:
            self.out.skip("publish rate limit → 429 with Retry-After", "use --check-rate-limit")
        else:
            def rate():
                key = "conf-%s-rate" % self.run
                for i in range(400):
                    r = self.cl.req("POST", "/", self.a.publish_key,
                                    body={"type": self.type, "text": "rate", "idempotency_key": key})
                    if r.status == 429:
                        err = is_error_shape(r, 429)
                        expect(not err, err)
                        expect(r.header("Retry-After"), "429 without Retry-After")
                        return
                    expect(r.status in (200, 201), r.short())
                raise Fail("400 publishes in a row were never rate limited")
            self.check("publish rate limit → 429 with Retry-After", rate)

        if not self.a.check_gap:
            self.out.skip("gap frame after > 1000 missed events", "use --check-gap (publishes ~1010 events)")
        else:
            self.check("gap frame after > 1000 missed events", self.gap)

    def gap(self):
        start = self.mine(self.a.reader_key, limit=1)["events"]
        expect(start, "no cursor to resume from")
        cursor = start[0]["cursor"]
        total = 1010
        sent = 0
        while sent < total:
            n = min(100, total - sent)
            body = {"events": [{"type": self.type, "text": "gap %d" % (sent + i), "severity": "debug",
                                "display": {"lifetime": 1}} for i in range(n)]}
            r = self.cl.req("POST", "/batch", self.a.publish_key, body=body)
            if r.status == 404:
                for i in range(n):
                    self.publish("gap %d" % (sent + i), display={"lifetime": 1})
            elif r.status == 429:
                time.sleep(float(r.header("Retry-After") or 2))
                continue
            else:
                expect(r.status in (200, 201), r.short())
            sent += n
        s = self.stream(self.a.reader_key, {"source": self.source}, last_event_id=cursor)
        expect(s.status == 200, "stream: HTTP %s" % s.status)
        f = s.next(lambda f: f["event"] in ("gap", "event"), 10)
        expect(f is not None and f["event"] == "gap", "first frame must be `gap`, got %r" % (f and f["event"]))
        d = f["data"]
        expect(isinstance(d.get("skipped"), int) and d["skipped"] >= 10 and d.get("after") == cursor
               and isinstance(d.get("resume"), str), "gap data must be {after, skipped, resume}: %r" % d)
        n = len([x for x in s.collect(5) if x["event"] == "event"])
        expect(n == 1000, "expected exactly 1000 replayed events after the gap, got %d" % n)
        s.close()

    def cleanup(self):
        for s in self.streams:
            s.close()
        for eid in self.sticky_ids:
            for k in (self.a.reader_key, self.a.reader_key_2):
                if k:
                    try:
                        self.cl.req("POST", "/%s/dismiss" % quote(eid), k)
                    except Exception:
                        pass


def main():
    ap = argparse.ArgumentParser(description="Black-box conformance test for an Ambient protocol (ambient/1) hub.")
    ap.add_argument("base_url", help="the hub's base URL, e.g. https://hub.example.com/v1/events")
    ap.add_argument("--publish-key", required=True, default=os.environ.get("AMBIENT_PUBLISH_KEY"))
    ap.add_argument("--reader-key", required=True, help="reader granted the publish key's source")
    ap.add_argument("--reader-key-2", help="a different reader, also granted that source")
    ap.add_argument("--restricted-reader", help="a reader NOT granted that source")
    ap.add_argument("--check-rate-limit", action="store_true", help="hammer the publish key until 429")
    ap.add_argument("--check-gap", action="store_true", help="publish ~1010 events to test the gap frame")
    ap.add_argument("--slow", action="store_true", help="also wait for a keepalive (up to 21 s)")
    ap.add_argument("--insecure", action="store_true", help="skip TLS verification")
    ap.add_argument("--no-color", action="store_true")
    a = ap.parse_args()

    out = Out(color=sys.stdout.isatty() and not a.no_color and not os.environ.get("NO_COLOR"))
    run = Run(a, out)
    t0 = time.time()
    print(out.c("1", "Ambient conformance") + "  " + run.cl.base)
    print("run %s · events are published as type %s" % (run.run, run.type))
    try:
        run.docs()
        run.auth()
        if run.source is None or run.reader is None:
            print(out.c("31", "\ncannot continue without a working publish key and reader key"))
        else:
            run.publish_section()
            run.batch()
            run.listing()
            run.sources()
            run.dismiss()
            run.streaming()
            run.grants()
            run.limits()
    except KeyboardInterrupt:
        print("\ninterrupted")
    finally:
        run.cleanup()

    print()
    summary = "%d passed, %d failed, %d warnings, %d skipped  (%.1f s)" % (
        out.passed, out.failed, out.warned, out.skipped, time.time() - t0)
    if out.failed:
        print(out.c("31;1", "NOT CONFORMANT") + "  " + summary)
        for name, why in out.failures:
            print("  ✗ %s: %s" % (name, why))
    else:
        print(out.c("32;1", "CONFORMANT") + "  " + summary)
    sys.exit(1 if out.failed else 0)


if __name__ == "__main__":
    main()
