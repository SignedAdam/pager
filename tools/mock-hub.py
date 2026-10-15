#!/usr/bin/env python3
"""A small Ambient hub for tests. Implements docs/protocol.md (ambient/1).

Not the reference hub: no SQLite, no admin, no rate limits. It exists so the
Pager client can be exercised end to end without a real server. Standard
library only.

    python3 tools/mock-hub.py --port 8787 --base /v1/events \\
        --publish pub-test:levi-test:Levi\\ test:#c7ff00 \\
        --reader read-adam:adam-mac:* --reader read-bob:bob:deploys \\
        --db /tmp/mock-hub.json

Keys are KEY:SOURCE[:NAME[:COLOR]] for publish keys and KEY:READER:SOURCES
(comma separated, or *) for reader keys. With --db, events and dismissals
survive a restart, so a client can be tested resuming across one.
"""
import argparse
import json
import queue
import re
import sys
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

SEVERITIES = ["debug", "info", "notice", "warn", "error", "critical"]
DISPLAY = {
    "lifetime": None, "layout": {"split", "inline"},
    "effect": {"none", "blink", "flash", "highlight", "wave", "gradient"},
    "target": {"emphasis", "message"}, "period": None, "color": None,
}
WRITABLE = {"type", "text", "severity", "detail", "subject", "url", "occurred_at", "display", "data", "idempotency_key"}


def now():
    return datetime.now(timezone.utc)


def stamp(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(text):
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(timezone.utc)
    except Exception:
        return None


class Problem(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


class Hub:
    def __init__(self, args):
        self.args = args
        self.lock = threading.RLock()
        self.publish = {}   # key -> {source, name, color}
        self.readers = {}   # key -> {reader, sources: set or None}
        for spec in args.publish:
            parts = spec.split(":")
            key, source = parts[0], parts[1]
            self.publish[key] = {"source": source, "name": parts[2] if len(parts) > 2 else source,
                                 "color": parts[3] if len(parts) > 3 else None}
        for spec in args.reader:
            key, reader, sources = spec.split(":", 2)
            self.readers[key] = {"reader": reader, "sources": None if sources == "*" else set(sources.split(","))}
        self.events = []      # stored records, oldest first, without dismissed_at
        self.dismissed = {}   # reader -> {event id: time}
        self.idempotency = {}  # source + key -> event id
        self.streams = []     # [reader, grant, filter, queue]
        self.load()

    # ---- persistence

    def load(self):
        if not self.args.db:
            return
        try:
            data = json.load(open(self.args.db))
        except Exception:
            return
        self.events = data.get("events", [])
        self.dismissed = data.get("dismissed", {})
        self.idempotency = data.get("idempotency", {})

    def save(self):
        if self.args.db:
            with open(self.args.db, "w") as f:
                json.dump({"events": self.events, "dismissed": self.dismissed, "idempotency": self.idempotency}, f)

    # ---- auth

    def auth(self, header, kind):
        if not header.startswith("Bearer "):
            raise Problem(401, "unauthorized", "send Authorization: Bearer <key>")
        key = header[7:].strip()
        if key in self.publish:
            if kind != "publish" and kind != "either":
                raise Problem(403, "wrong_key_kind", "a publish key can only POST events")
            return "publish", self.publish[key]
        if key in self.readers:
            if kind != "reader" and kind != "either":
                raise Problem(403, "wrong_key_kind", "a reader key cannot publish")
            return "reader", self.readers[key]
        raise Problem(401, "unauthorized", "unknown or revoked key")

    @staticmethod
    def granted(reader, source):
        return reader["sources"] is None or source in reader["sources"]

    def view(self, event, reader):
        out = dict(event)
        out["dismissed_at"] = self.dismissed.get(reader["reader"], {}).get(event["id"])
        return out

    # ---- publish

    def validate(self, body, pub):
        if not isinstance(body, dict):
            raise Problem(400, "invalid_body", "the body must be a JSON object")
        if "source" in body:
            raise Problem(400, "source_from_key", "do not send source; it comes from the publish key")
        unknown = set(body) - WRITABLE
        if unknown:
            raise Problem(400, "unknown_field", "unknown field(s): " + ", ".join(sorted(unknown)))
        text, typ = body.get("text"), body.get("type")
        if not isinstance(text, str) or not text.strip() or len(text) > 300:
            raise Problem(400, "invalid_text", "text is required, at most 300 characters")
        if not isinstance(typ, str) or not re.fullmatch(r"[a-z0-9._-]{1,48}", typ):
            raise Problem(400, "invalid_type", "type is required: 1 to 48 of a-z 0-9 . _ -")
        severity = body.get("severity", "info")
        if severity not in SEVERITIES:
            raise Problem(400, "invalid_severity", "severity is one of " + ", ".join(SEVERITIES))
        for field, limit in (("detail", 1000), ("subject", 80)):
            value = body.get(field)
            if value is not None and (not isinstance(value, str) or len(value) > limit):
                raise Problem(400, "invalid_" + field, f"{field} is text, at most {limit} characters")
        url = body.get("url")
        if url is not None and not (isinstance(url, str) and re.match(r"^https?://[^\s/]+", url)):
            raise Problem(400, "invalid_url", "url must be http(s)")
        display = body.get("display")
        if display is not None:
            if not isinstance(display, dict):
                raise Problem(400, "invalid_display", "display is an object")
            for k, v in display.items():
                if k not in DISPLAY:
                    raise Problem(400, "invalid_display", f"unknown display key {k}; allowed: {', '.join(DISPLAY)}")
                allowed = DISPLAY[k]
                if allowed is not None and v not in allowed:
                    raise Problem(400, "invalid_display", f"display.{k} is one of {', '.join(sorted(allowed))}")
            life = display.get("lifetime")
            if life is not None and life != "sticky" and not (isinstance(life, (int, float)) and 1 <= life <= 86400):
                raise Problem(400, "invalid_display", 'display.lifetime is 1..86400 seconds or "sticky"')
            period = display.get("period")
            if period is not None and not (isinstance(period, (int, float)) and 0.5 <= period <= 10):
                raise Problem(400, "invalid_display", "display.period is 0.5..10")
            color = display.get("color")
            if color is not None and not (isinstance(color, str) and re.fullmatch(r"#[0-9a-fA-F]{6}", color)):
                raise Problem(400, "invalid_display", "display.color is #rrggbb")
        data = body.get("data")
        if data is not None and (not isinstance(data, dict) or len(json.dumps(data)) > 8192):
            raise Problem(400, "invalid_data", "data is an object of at most 8 KB")
        idem = body.get("idempotency_key")
        if idem is not None and (not isinstance(idem, str) or len(idem) > 128):
            raise Problem(400, "invalid_idempotency_key", "idempotency_key is at most 128 characters")

    def add(self, body, pub):
        self.validate(body, pub)
        with self.lock:
            idem = body.get("idempotency_key")
            if idem and (pub["source"] + "\0" + idem) in self.idempotency:
                original = self.idempotency[pub["source"] + "\0" + idem]
                return 200, next(e for e in self.events if e["id"] == original)
            received = now()
            occurred = parse_time(body.get("occurred_at") or "") or received
            occurred = min(max(occurred, received - timedelta(days=7)), received + timedelta(days=7))
            cursor = str(int(self.events[-1]["cursor"]) + 1) if self.events else "1"
            event = {
                "id": "evt_" + uuid.uuid4().hex[:12], "cursor": cursor, "source": pub["source"],
                "source_name": pub["name"], "source_color": pub["color"], "type": body["type"],
                "severity": body.get("severity", "info"), "text": body["text"],
                "occurred_at": stamp(occurred), "received_at": stamp(received),
            }
            for k in ("detail", "subject", "url", "display", "data"):
                if body.get(k) is not None:
                    event[k] = body[k]
            self.events.append(event)
            if idem:
                self.idempotency[pub["source"] + "\0" + idem] = event["id"]
            self.save()
            for reader, grant, wanted, q in list(self.streams):
                if self.granted(grant, event["source"]) and (not wanted or event["source"] in wanted):
                    q.put(("event", self.view(event, grant)))
            return 201, event

    # ---- read

    def visible(self, reader, wanted=None):
        return [e for e in self.events
                if self.granted(reader, e["source"]) and (not wanted or e["source"] in wanted)]

    def list(self, reader, query):
        q = {k: v[-1] for k, v in query.items()}
        wanted = set(q["source"].split(",")) if q.get("source") else None
        events = self.visible(reader, wanted)
        if q.get("type"):
            events = [e for e in events if e["type"] == q["type"]]
        if q.get("severity_min") in SEVERITIES:
            floor = SEVERITIES.index(q["severity_min"])
            events = [e for e in events if SEVERITIES.index(e["severity"]) >= floor]
        if q.get("q"):
            needle = q["q"].lower()
            events = [e for e in events if needle in (e["text"] + " " + e.get("detail", "")).lower()]
        mine = self.dismissed.get(reader["reader"], {})
        if q.get("sticky") == "open":
            events = [e for e in events if (e.get("display") or {}).get("lifetime") == "sticky" and e["id"] not in mine]
        if q.get("before"):
            events = [e for e in events if int(e["cursor"]) < int(q["before"])]
        limit = max(1, min(500, int(q.get("limit", 100))))
        if q.get("after"):
            events = [e for e in events if int(e["cursor"]) > int(q["after"])][:limit]
        else:
            events = list(reversed(events))[:limit]
        latest = self.visible(reader)
        return {"events": [self.view(e, reader) for e in events],
                "next_before": events[-1]["cursor"] if events and not q.get("after") else None,
                "latest_cursor": latest[-1]["cursor"] if latest else None}

    def dismiss(self, reader, event_id, on):
        with self.lock:
            event = next((e for e in self.events if e["id"] == event_id), None)
            if event is None or not self.granted(reader, event["source"]):
                raise Problem(404, "not_found", "no such event for this key")
            mine = self.dismissed.setdefault(reader["reader"], {})
            if on:
                mine.setdefault(event_id, stamp(now()))
            else:
                mine.pop(event_id, None)
            self.save()
            state = {"id": event_id, "dismissed_at": mine.get(event_id)}
            for who, grant, wanted, q in list(self.streams):
                if who == reader["reader"]:
                    q.put(("state", state))
            return state


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    hub = None  # type: Hub, set in main()

    def log_message(self, fmt, *args):
        if self.hub.args.verbose:
            sys.stderr.write("mock-hub %s %s\n" % (self.address_string(), fmt % args))

    def note(self, text):
        sys.stderr.write(f"mock-hub {text}\n")
        sys.stderr.flush()

    def route(self):
        base = self.hub.args.base.rstrip("/")
        parts = urlsplit(self.path)
        path = parts.path.rstrip("/") if parts.path != "/" else ""
        if not (path == base or path.startswith(base + "/")):
            raise Problem(404, "not_found", "not under " + (base or "/"))
        return path[len(base):], parse_qs(parts.query)

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def fail(self, problem):
        self.send_json(problem.status, {"error": {"code": problem.code, "message": problem.message}})

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > 16 * 1024:
            raise Problem(413, "too_large", "body is at most 16 KB")
        try:
            return json.loads(self.rfile.read(length) or b"null")
        except ValueError:
            raise Problem(400, "invalid_json", "the body is not JSON")

    def handle_any(self, method):
        try:
            rel, query = self.route()
            auth = self.headers.get("Authorization", "")
            if method == "GET" and rel == "/docs":
                data = DOCS.replace("{base}", self.hub.args.base).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/markdown; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            elif method == "GET" and rel == "/info":
                kind, who = self.hub.auth(auth, "either")
                sources = sorted({e["source"] for e in self.hub.events} | {p["source"] for p in self.hub.publish.values()})
                info = {"protocol": "ambient/1", "name": self.hub.args.name, "key": kind,
                        "features": ["batch", "search"], "docs": self.hub.args.base + "/docs"}
                if kind == "reader":
                    info["reader"] = who["reader"]
                    info["sources"] = [s for s in sources if self.hub.granted(who, s)]
                else:
                    info["sources"] = [who["source"]]
                self.send_json(200, info)
            elif method == "POST" and rel == "":
                _, pub = self.hub.auth(auth, "publish")
                status, event = self.hub.add(self.body(), pub)
                self.note(f"publish {event['id']} cursor {event['cursor']} -> {status}")
                self.send_json(status, event)
            elif method == "POST" and rel == "/batch":
                _, pub = self.hub.auth(auth, "publish")
                body = self.body()
                items = body.get("events") if isinstance(body, dict) else None
                if not isinstance(items, list) or len(items) > 100:
                    raise Problem(400, "invalid_batch", '{"events":[...]} with at most 100')
                self.send_json(200, {"events": [self.hub.add(item, pub)[1] for item in items]})
            elif method == "GET" and rel == "":
                _, reader = self.hub.auth(auth, "reader")
                self.send_json(200, self.hub.list(reader, query))
            elif method == "GET" and rel == "/sources":
                _, reader = self.hub.auth(auth, "reader")
                out = {}
                day = now() - timedelta(days=1)
                for e in self.hub.visible(reader):
                    s = out.setdefault(e["source"], {"slug": e["source"], "name": e["source_name"],
                                                     "color": e["source_color"], "last_event_at": None, "count_24h": 0})
                    s["last_event_at"] = e["received_at"]
                    if parse_time(e["received_at"]) >= day:
                        s["count_24h"] += 1
                self.send_json(200, {"sources": list(out.values())})
            elif method == "GET" and rel == "/stream":
                _, reader = self.hub.auth(auth, "reader")
                self.stream(reader, query)
            elif method in ("POST", "DELETE") and re.fullmatch(r"/[^/]+/dismiss", rel):
                _, reader = self.hub.auth(auth, "reader")
                event_id = unquote(rel.split("/")[1])
                state = self.hub.dismiss(reader, event_id, method == "POST")
                self.note(f"{'dismiss' if method == 'POST' else 'undismiss'} {event_id} by {reader['reader']}")
                self.send_json(200, state)
            else:
                raise Problem(404, "not_found", f"no route {method} {rel or '/'}")
        except Problem as problem:
            if problem.status >= 400:
                self.note(f"{method} {self.path} -> {problem.status} {problem.code}")
            self.fail(problem)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def stream(self, reader, query):
        hub = self.hub
        after = self.headers.get("Last-Event-ID") or (query.get("after") or [None])[-1]
        wanted = set(query["source"][-1].split(",")) if query.get("source") else None
        q = queue.Queue()
        entry = [reader["reader"], reader, wanted, q]
        with hub.lock:
            backlog = [e for e in hub.visible(reader, wanted) if after and int(e["cursor"]) > int(after)]
            hub.streams.append(entry)
        self.note(f"stream open reader={reader['reader']} last-event-id={after or '-'} replay={len(backlog)}")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def chunk(text):
            data = text.encode()
            self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
            self.wfile.flush()

        def frame(kind, payload):
            if kind == "event":
                chunk(f"id: {payload['cursor']}\nevent: event\ndata: {json.dumps(payload)}\n\n")
            else:
                chunk(f"event: {kind}\ndata: {json.dumps(payload)}\n\n")

        try:
            limit = hub.args.replay_max
            if len(backlog) > limit:
                frame("gap", {"missed": len(backlog) - limit})
                backlog = backlog[-limit:]
            for e in backlog:
                frame("event", hub.view(e, reader))
            chunk(": connected\n\n")
            while not hub.stopping.is_set():
                try:
                    kind, payload = q.get(timeout=hub.args.keepalive)
                    frame(kind, payload)
                except queue.Empty:
                    if hub.args.silent:
                        continue
                    chunk(": keepalive\n\n")
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            with hub.lock:
                if entry in hub.streams:
                    hub.streams.remove(entry)
            self.note(f"stream closed reader={reader['reader']}")
            self.close_connection = True

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_DELETE(self):
        self.handle_any("DELETE")


DOCS = """# Mock Ambient hub

Base URL: {base}. Publish with `POST {base}` and a publish key; see docs/protocol.md in the pager repo.
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--base", default="/v1/events")
    parser.add_argument("--name", default="Mock hub")
    parser.add_argument("--publish", action="append", default=[])
    parser.add_argument("--reader", action="append", default=[])
    parser.add_argument("--db")
    parser.add_argument("--keepalive", type=float, default=20)
    parser.add_argument("--replay-max", type=int, default=1000)
    parser.add_argument("--silent", action="store_true", help="never send keepalives (to test a reader's watchdog)")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    if not args.publish:
        args.publish = ["pub-test:levi-test:Levi test:#c7ff00"]
    if not args.reader:
        args.reader = ["read-test:tester:*"]
    hub = Hub(args)
    hub.stopping = threading.Event()
    Handler.hub = hub
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    sys.stderr.write(f"mock-hub listening on http://{args.host}:{args.port}{args.base} ({len(hub.events)} stored)\n")
    sys.stderr.flush()
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        hub.stopping.set()
        server.server_close()


if __name__ == "__main__":
    main()
