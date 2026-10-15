#!/usr/bin/env python3
"""ambient-hub: the reference hub for the Ambient protocol, version 1.

One file, Python 3.9+ standard library only, SQLite in WAL mode.
The wire contract is docs/protocol.md. Run `ambient-hub.py --help` for commands.

    python3 ambient-hub.py source add deploys --name Deploys --color "#c7ff00"
    python3 ambient-hub.py key publish deploys --label ci
    python3 ambient-hub.py key reader adam-mac --all
    python3 ambient-hub.py serve --db ./hub.db --listen 0.0.0.0:8790 --public-url https://hub.example.com
"""

import argparse
import datetime
import hashlib
import json
import math
import os
import queue
import re
import secrets
import select
import signal
import socket
import sqlite3
import string
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

VERSION = "1.0.0"
PROTOCOL = "ambient/1"
FEATURES = ["batch", "search"]

SEVERITIES = ["debug", "info", "notice", "warn", "error", "critical"]
SEV_RANK = {s: i for i, s in enumerate(SEVERITIES)}

# Limits. The protocol defaults; /docs states whatever is in effect.
MAX_BODY = 16 * 1024
MAX_TEXT = 300
MAX_DETAIL = 1000
MAX_SUBJECT = 80
MAX_URL = 2048
MAX_DATA = 8 * 1024
MAX_IDEMPOTENCY_KEY = 128
IDEMPOTENCY_WINDOW = 7 * 86400
OCCURRED_CLAMP = 7 * 86400
MAX_BATCH = 100
BATCH_EVENTS_PER_TOKEN = 10
LIST_DEFAULT = 100
LIST_MAX = 500
REPLAY_MAX = 1000
RATE_PER_MIN = 120
RATE_BURST = 30
MAX_STREAMS_PER_KEY = 8
STREAM_QUEUE = 4096
DEFAULT_KEEPALIVE = 15.0
DEFAULT_RETENTION_DAYS = 90

SLUG_RE = re.compile(r"^[a-z0-9-]{2,48}$")
TYPE_RE = re.compile(r"^[a-z0-9._-]{1,48}$")
COLOR_RE = re.compile(r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$")
CURSOR_RE = re.compile(r"^[0-9]{1,18}$")
EVENT_ID_RE = re.compile(r"^evt_[0-9a-f]{16}$")
TS_RE = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2}):(\d{2})(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$")

DISPLAY_KEYS = ("lifetime", "layout", "effect", "target", "period", "color")
DISPLAY_ENUMS = {
    "layout": ("split", "inline"),
    "effect": ("none", "blink", "flash", "highlight", "wave", "gradient"),
    "target": ("emphasis", "message"),
}
EVENT_FIELDS = ("type", "text", "severity", "detail", "subject", "url", "occurred_at",
                "display", "data", "idempotency_key")

KEY_ALPHABET = string.ascii_letters + string.digits
KEY_PREFIX = {"publish": "ahp_", "reader": "ahr_"}
KEY_SHOWN = 12  # characters of a key kept in clear for `key list` / `key revoke`

UTC = datetime.timezone.utc


# ---------------------------------------------------------------------------
# time

def utcnow():
    return datetime.datetime.now(UTC)


def fmt_ts(dt):
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ts(value):
    """RFC 3339 -> aware datetime, or None."""
    m = TS_RE.match(value)
    if not m:
        return None
    y, mo, d, h, mi, s = (int(x) for x in m.groups()[:6])
    frac, tz = m.group(7), m.group(8)
    try:
        dt = datetime.datetime(y, mo, d, h, mi, min(s, 59), tzinfo=UTC)
    except ValueError:
        return None
    if frac:
        dt += datetime.timedelta(microseconds=int(round(float(frac) * 1e6)))
    if tz not in ("Z", "z"):
        sign = 1 if tz[0] == "+" else -1
        dt -= sign * datetime.timedelta(hours=int(tz[1:3]), minutes=int(tz[4:6]))
    return dt


# ---------------------------------------------------------------------------
# errors

class ApiError(Exception):
    def __init__(self, status, code, message, headers=None):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.headers = headers or {}

    def body(self):
        return {"error": {"code": self.code, "message": self.message}}


def bad(code, message):
    return ApiError(400, code, message)


class AdminError(Exception):
    pass


# ---------------------------------------------------------------------------
# database

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (
  k TEXT PRIMARY KEY,
  v TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sources (
  slug TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  color TEXT,
  retention_days INTEGER NOT NULL DEFAULT 90,
  created_at TEXT NOT NULL,
  archived_at TEXT
);
CREATE TABLE IF NOT EXISTS readers (
  id INTEGER PRIMARY KEY,
  label TEXT NOT NULL UNIQUE,
  all_sources INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS grants (
  reader_id INTEGER NOT NULL REFERENCES readers(id),
  source TEXT NOT NULL REFERENCES sources(slug),
  PRIMARY KEY (reader_id, source)
);
CREATE TABLE IF NOT EXISTS keys (
  id INTEGER PRIMARY KEY,
  prefix TEXT NOT NULL,
  hash TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL CHECK (kind IN ('publish', 'reader')),
  label TEXT,
  source TEXT REFERENCES sources(slug),
  reader_id INTEGER REFERENCES readers(id),
  created_at TEXT NOT NULL,
  last_used_at TEXT,
  revoked_at TEXT
);
CREATE TABLE IF NOT EXISTS events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  source TEXT NOT NULL,
  type TEXT NOT NULL,
  severity INTEGER NOT NULL,
  text TEXT NOT NULL,
  detail TEXT,
  subject TEXT,
  url TEXT,
  occurred_at TEXT NOT NULL,
  received_at TEXT NOT NULL,
  display TEXT,
  data TEXT,
  sticky INTEGER NOT NULL DEFAULT 0,
  idempotency_key TEXT
);
CREATE INDEX IF NOT EXISTS events_source_seq ON events(source, seq);
CREATE INDEX IF NOT EXISTS events_source_received ON events(source, received_at);
CREATE INDEX IF NOT EXISTS events_idem ON events(source, idempotency_key)
  WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS events_sticky ON events(seq) WHERE sticky = 1;
CREATE TABLE IF NOT EXISTS dismissals (
  reader_id INTEGER NOT NULL,
  event_seq INTEGER NOT NULL,
  dismissed_at TEXT NOT NULL,
  PRIMARY KEY (reader_id, event_seq)
);
"""


def open_db(path, init=True):
    conn = sqlite3.connect(path, timeout=15, isolation_level=None, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout = 15000")
    if not init:  # the schema and WAL mode were set up when the server started
        conn.execute("PRAGMA synchronous = NORMAL")
        conn.execute("PRAGMA foreign_keys = ON")
        return conn
    mode = conn.execute("PRAGMA journal_mode = WAL").fetchone()[0]
    if mode.lower() != "wal" and path != ":memory:":
        raise SystemExit("ambient-hub: could not put %s in WAL mode (got %s)" % (path, mode))
    conn.execute("PRAGMA synchronous = NORMAL")
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(SCHEMA)
    conn.execute("INSERT OR IGNORE INTO meta (k, v) VALUES ('schema', '1')")
    return conn


class tx:
    """BEGIN IMMEDIATE ... COMMIT. Serializes writers across threads and processes."""

    def __init__(self, conn):
        self.conn = conn

    def __enter__(self):
        self.conn.execute("BEGIN IMMEDIATE")
        return self.conn

    def __exit__(self, exc_type, exc, tb):
        if exc_type is None:
            self.conn.execute("COMMIT")
        else:
            self.conn.execute("ROLLBACK")
        return False


def bump_admin_version(conn):
    """Tell a running server that keys, grants or sources changed."""
    conn.execute("INSERT OR REPLACE INTO meta (k, v) VALUES ('admin_version', ?)",
                 (secrets.token_hex(8),))


def meta_get(conn, k):
    row = conn.execute("SELECT v FROM meta WHERE k = ?", (k,)).fetchone()
    return row[0] if row else None


# ---------------------------------------------------------------------------
# validation

def _opt_str(obj, name, limit, where):
    v = obj.get(name)
    if v is None:
        return None
    if not isinstance(v, str):
        raise bad("invalid_field", "%s%s: must be a string of at most %d characters" % (where, name, limit))
    if len(v) > limit:
        raise bad("invalid_field", "%s%s: %d characters; the limit is %d" % (where, name, len(v), limit))
    return v if v != "" else None


def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def normalize_color(v):
    v = v.lower()
    if len(v) == 4:
        v = "#" + "".join(c * 2 for c in v[1:])
    return v


def validate_display(d, where):
    if d is None:
        return None
    if not isinstance(d, dict):
        raise bad("invalid_field", "%sdisplay: must be an object with any of %s" % (where, ", ".join(DISPLAY_KEYS)))
    out = {}
    for k, v in d.items():
        if k not in DISPLAY_KEYS:
            raise bad("invalid_field", "%sdisplay.%s: unknown display hint; allowed: %s" % (where, k, ", ".join(DISPLAY_KEYS)))
        if v is None:
            continue
        if k == "lifetime":
            if v == "sticky":
                out[k] = v
            elif _is_number(v) and float(v).is_integer() and 1 <= v <= 86400:
                out[k] = int(v)
            else:
                raise bad("invalid_field", "%sdisplay.lifetime: must be whole seconds 1..86400 or \"sticky\"" % where)
        elif k in DISPLAY_ENUMS:
            if v not in DISPLAY_ENUMS[k]:
                raise bad("invalid_field", "%sdisplay.%s: must be one of %s" % (where, k, " | ".join(DISPLAY_ENUMS[k])))
            out[k] = v
        elif k == "period":
            if not _is_number(v) or not (0.5 <= v <= 10):
                raise bad("invalid_field", "%sdisplay.period: must be a number of seconds 0.5..10" % where)
            out[k] = int(v) if float(v).is_integer() else float(v)
        elif k == "color":
            if not isinstance(v, str) or not COLOR_RE.match(v):
                raise bad("invalid_field", "%sdisplay.color: must be a hex color like \"#ff5f57\"" % where)
            out[k] = normalize_color(v)
    return out


def validate_event(obj, now, where=""):
    """Check a publish body. Returns clean fields or raises ApiError(400)."""
    if not isinstance(obj, dict):
        raise bad("invalid_json", "%sthe event must be a JSON object" % (where or "body: "))
    if "source" in obj:
        raise ApiError(400, "source_from_key",
                       "%ssource: not allowed in the body; the source comes from the publish key" % where)
    for k in obj:
        if k not in EVENT_FIELDS:
            raise bad("unknown_field", "%s%s: unknown field; allowed: %s" % (where, k, ", ".join(EVENT_FIELDS)))

    t = obj.get("type")
    if not isinstance(t, str) or not TYPE_RE.match(t):
        raise bad("invalid_field", "%stype: required; 1-48 characters of a-z 0-9 . _ - (e.g. \"deploy.failed\")" % where)

    text = obj.get("text")
    if not isinstance(text, str) or not text.strip():
        raise bad("invalid_field", "%stext: required; a non-empty string of at most %d characters" % (where, MAX_TEXT))
    if len(text) > MAX_TEXT:
        raise bad("invalid_field", "%stext: %d characters; the limit is %d (put the rest in detail)" % (where, len(text), MAX_TEXT))

    sev = obj.get("severity")
    if sev is None:
        sev = "info"
    if sev not in SEV_RANK:
        raise bad("invalid_field", "%sseverity: must be one of %s" % (where, " | ".join(SEVERITIES)))

    detail = _opt_str(obj, "detail", MAX_DETAIL, where)
    subject = _opt_str(obj, "subject", MAX_SUBJECT, where)

    url = _opt_str(obj, "url", MAX_URL, where)
    if url is not None:
        parts = urlsplit(url)
        if parts.scheme not in ("http", "https") or not parts.netloc:
            raise bad("invalid_field", "%surl: must be an absolute http:// or https:// URL" % where)

    occurred = obj.get("occurred_at")
    if occurred is None:
        occurred_dt = now
    else:
        occurred_dt = parse_ts(occurred) if isinstance(occurred, str) else None
        if occurred_dt is None:
            raise bad("invalid_field", "%soccurred_at: must be an RFC 3339 time like \"2026-10-15T10:02:03Z\"" % where)
        lo = now - datetime.timedelta(seconds=OCCURRED_CLAMP)
        hi = now + datetime.timedelta(seconds=OCCURRED_CLAMP)
        occurred_dt = min(max(occurred_dt, lo), hi)

    display = validate_display(obj.get("display"), where)

    data = obj.get("data")
    if data is not None:
        if not isinstance(data, dict):
            raise bad("invalid_field", "%sdata: must be a JSON object" % where)
        data_json = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
        if len(data_json.encode("utf-8")) > MAX_DATA:
            raise bad("invalid_field", "%sdata: %d bytes as JSON; the limit is %d" % (
                where, len(data_json.encode("utf-8")), MAX_DATA))
    else:
        data_json = None

    idem = obj.get("idempotency_key")
    if idem is not None:
        if not isinstance(idem, str) or not (1 <= len(idem) <= MAX_IDEMPOTENCY_KEY):
            raise bad("invalid_field", "%sidempotency_key: must be a string of 1..%d characters" % (where, MAX_IDEMPOTENCY_KEY))

    return {
        "type": t,
        "text": text,
        "severity": SEV_RANK[sev],
        "detail": detail,
        "subject": subject,
        "url": url,
        "occurred_at": fmt_ts(occurred_dt),
        "display": json.dumps(display, separators=(",", ":")) if display else None,
        "data": data_json,
        "sticky": 1 if display and display.get("lifetime") == "sticky" else 0,
        "idempotency_key": idem,
    }


def parse_cursor(value, name):
    if value is None or value == "":
        return None
    if not CURSOR_RE.match(value):
        raise bad("invalid_cursor", "%s: not a cursor from this hub (expected the cursor string of an event)" % name)
    return int(value)


# ---------------------------------------------------------------------------
# events

EVENT_SELECT = (
    "SELECT e.seq, e.id, e.source, s.name AS source_name, s.color AS source_color, e.type, "
    "e.severity, e.text, e.detail, e.subject, e.url, e.occurred_at, e.received_at, e.display, e.data")

_MISSING = object()


def event_json(row, dismissed=_MISSING):
    ev = {
        "id": row["id"],
        "cursor": str(row["seq"]),
        "source": row["source"],
        "source_name": row["source_name"],
        "source_color": row["source_color"],
        "type": row["type"],
        "severity": SEVERITIES[row["severity"]],
        "text": row["text"],
        "detail": row["detail"],
        "subject": row["subject"],
        "url": row["url"],
        "occurred_at": row["occurred_at"],
        "received_at": row["received_at"],
        "display": json.loads(row["display"]) if row["display"] else {},
        "data": json.loads(row["data"]) if row["data"] else {},
    }
    if dismissed is not _MISSING:
        ev["dismissed_at"] = dismissed
    return ev


def publish_events(conn, source, cleans, now):
    """Store events for one source in one transaction. Returns [(row, created)]."""
    received = fmt_ts(now)
    window = fmt_ts(now - datetime.timedelta(seconds=IDEMPOTENCY_WINDOW))
    out = []
    with tx(conn):
        src = conn.execute("SELECT archived_at FROM sources WHERE slug = ?", (source,)).fetchone()
        if src is None:
            raise ApiError(403, "source_archived", "this key's source no longer exists")
        if src["archived_at"]:
            raise ApiError(403, "source_archived", "source '%s' is archived and accepts no events" % source)
        for c in cleans:
            if c["idempotency_key"] is not None:
                row = conn.execute(
                    EVENT_SELECT + " FROM events e JOIN sources s ON s.slug = e.source "
                    "WHERE e.source = ? AND e.idempotency_key = ? AND e.received_at >= ? "
                    "ORDER BY e.seq LIMIT 1", (source, c["idempotency_key"], window)).fetchone()
                if row is not None:
                    out.append((row, False))
                    continue
            eid = "evt_" + secrets.token_hex(8)
            conn.execute(
                "INSERT INTO events (id, source, type, severity, text, detail, subject, url, occurred_at, "
                "received_at, display, data, sticky, idempotency_key) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (eid, source, c["type"], c["severity"], c["text"], c["detail"], c["subject"], c["url"],
                 c["occurred_at"], received, c["display"], c["data"], c["sticky"], c["idempotency_key"]))
            row = conn.execute(EVENT_SELECT + " FROM events e JOIN sources s ON s.slug = e.source "
                               "WHERE e.id = ?", (eid,)).fetchone()
            out.append((row, True))
    return out


def prune(conn, now=None):
    """Delete events older than each source's retention. Returns rows deleted."""
    now = now or utcnow()
    total = 0
    for s in conn.execute("SELECT slug, retention_days FROM sources WHERE retention_days > 0").fetchall():
        cutoff = fmt_ts(now - datetime.timedelta(days=s["retention_days"]))
        with tx(conn):
            conn.execute("DELETE FROM dismissals WHERE event_seq IN "
                         "(SELECT seq FROM events WHERE source = ? AND received_at < ?)", (s["slug"], cutoff))
            total += conn.execute("DELETE FROM events WHERE source = ? AND received_at < ?",
                                  (s["slug"], cutoff)).rowcount
    with tx(conn):
        conn.execute("INSERT OR REPLACE INTO meta (k, v) VALUES ('last_prune', ?)", (fmt_ts(now),))
    return total


# ---------------------------------------------------------------------------
# keys

def hash_key(key):
    return hashlib.sha256(key.encode("utf-8")).hexdigest()


def new_key(kind):
    return KEY_PREFIX[kind] + "".join(secrets.choice(KEY_ALPHABET) for _ in range(32))


class Principal:
    __slots__ = ("kind", "key_id", "label", "source", "reader_id", "reader", "grant")

    def __init__(self, **kw):
        for k in self.__slots__:
            setattr(self, k, kw.get(k))


def load_grant(conn, reader_id):
    """None means all sources; otherwise a frozenset of slugs."""
    r = conn.execute("SELECT all_sources FROM readers WHERE id = ?", (reader_id,)).fetchone()
    if r is None:
        return frozenset()
    if r["all_sources"]:
        return None
    return frozenset(x[0] for x in conn.execute("SELECT source FROM grants WHERE reader_id = ?", (reader_id,)))


def authenticate(conn, header):
    if not header or not header.startswith("Bearer "):
        raise ApiError(401, "unauthorized", "send Authorization: Bearer <key>",
                       {"WWW-Authenticate": 'Bearer realm="ambient"'})
    token = header[7:].strip()
    row = conn.execute(
        "SELECT k.id, k.kind, k.label, k.source, k.reader_id, k.revoked_at, r.label AS reader "
        "FROM keys k LEFT JOIN readers r ON r.id = k.reader_id WHERE k.hash = ?",
        (hash_key(token),)).fetchone()
    if row is None:
        raise ApiError(401, "unauthorized", "unknown key", {"WWW-Authenticate": 'Bearer error="invalid_token"'})
    if row["revoked_at"]:
        raise ApiError(401, "unauthorized", "this key was revoked",
                       {"WWW-Authenticate": 'Bearer error="invalid_token"'})
    p = Principal(kind=row["kind"], key_id=row["id"], label=row["label"], source=row["source"],
                  reader_id=row["reader_id"], reader=row["reader"])
    if p.kind == "reader":
        p.grant = load_grant(conn, p.reader_id)
    return p


def visible_sources(conn, grant):
    rows = conn.execute("SELECT slug FROM sources WHERE archived_at IS NULL ORDER BY slug").fetchall()
    return [r[0] for r in rows if grant is None or r[0] in grant]


# ---------------------------------------------------------------------------
# rate limiting

class TokenBuckets:
    def __init__(self, per_min, burst):
        self.rate = per_min / 60.0
        self.burst = float(burst)
        self.lock = threading.Lock()
        self.buckets = {}

    def take(self, key_id, cost=1):
        """Returns 0 if allowed, otherwise seconds to wait."""
        now = time.monotonic()
        with self.lock:
            tokens, t = self.buckets.get(key_id, (self.burst, now))
            tokens = min(self.burst, tokens + (now - t) * self.rate)
            if tokens >= cost:
                self.buckets[key_id] = (tokens - cost, now)
                return 0
            self.buckets[key_id] = (tokens, now)
            return max(1, int(math.ceil((cost - tokens) / self.rate)))


# ---------------------------------------------------------------------------
# streams and fan-out

class Stream:
    def __init__(self, key_id, reader_id, sources):
        self.key_id = key_id
        self.reader_id = reader_id
        self.sources = sources  # frozenset or None (client filter)
        self.q = queue.Queue(maxsize=STREAM_QUEUE)
        self.closed = False

    def offer(self, item):
        if self.closed:
            return
        try:
            self.q.put_nowait(item)
        except queue.Full:
            # Too slow to keep up. Close it; the client resumes with Last-Event-ID.
            self.close()

    def close(self):
        if not self.closed:
            self.closed = True
            try:
                self.q.put_nowait(("close", None, None))
            except queue.Full:
                pass


class Hub:
    def __init__(self, cfg):
        self.cfg = cfg
        self.local = threading.local()
        self.stop = threading.Event()
        self.lock = threading.Lock()          # streams and grant cache
        self.fan_lock = threading.Lock()      # fan-out order
        self.streams = set()
        self.grants = {}                      # reader_id -> grant
        self.rate = TokenBuckets(RATE_PER_MIN, RATE_BURST)
        self.last_used = {}
        conn = self.conn()
        self.last_seq = conn.execute("SELECT COALESCE(MAX(seq), 0) FROM events").fetchone()[0]
        self.admin_version = meta_get(conn, "admin_version")

    def conn(self):
        c = getattr(self.local, "conn", None)
        if c is None:
            c = open_db(self.cfg.db, init=False)
            self.local.conn = c
        return c

    # -- streams

    def register(self, stream):
        grant = load_grant(self.conn(), stream.reader_id)
        with self.lock:
            n = sum(1 for s in self.streams if s.key_id == stream.key_id)
            if n >= MAX_STREAMS_PER_KEY:
                raise ApiError(429, "too_many_streams",
                               "this key already has %d open streams; close one first" % MAX_STREAMS_PER_KEY,
                               {"Retry-After": "5"})
            self.grants[stream.reader_id] = grant
            self.streams.add(stream)

    def unregister(self, stream):
        with self.lock:
            self.streams.discard(stream)

    def close_all(self):
        with self.lock:
            for s in list(self.streams):
                s.close()

    def poke(self):
        """Fan out every stored event the streams have not seen yet, in cursor order."""
        with self.fan_lock:
            conn = self.conn()
            while True:
                rows = conn.execute(
                    EVENT_SELECT + " FROM events e JOIN sources s ON s.slug = e.source "
                    "WHERE e.seq > ? ORDER BY e.seq LIMIT 500", (self.last_seq,)).fetchall()
                if not rows:
                    return
                with self.lock:
                    streams = list(self.streams)
                    grants = dict(self.grants)
                for row in rows:
                    payload = json.dumps(event_json(row, None), separators=(",", ":"), ensure_ascii=False)
                    src = row["source"]
                    for s in streams:
                        g = grants.get(s.reader_id, frozenset())
                        if g is not None and src not in g:
                            continue
                        if s.sources is not None and src not in s.sources:
                            continue
                        s.offer(("event", row["seq"], payload))
                    self.last_seq = row["seq"]

    def emit_state(self, reader_id, source, event_id, dismissed_at):
        payload = json.dumps({"id": event_id, "dismissed_at": dismissed_at}, separators=(",", ":"))
        with self.lock:
            streams = [s for s in self.streams if s.reader_id == reader_id]
        for s in streams:
            if s.sources is None or source in s.sources:
                s.offer(("state", None, payload))

    # -- background work

    def refresh_admin(self):
        """Pick up key revocations and grant changes made by the CLI."""
        conn = self.conn()
        v = meta_get(conn, "admin_version")
        if v == self.admin_version:
            return
        self.admin_version = v
        with self.lock:
            streams = list(self.streams)
        readers = {s.reader_id for s in streams}
        grants = {r: load_grant(conn, r) for r in readers}
        keys = {s.key_id for s in streams}
        dead = set()
        if keys:
            marks = ",".join("?" * len(keys))
            dead = {r[0] for r in conn.execute(
                "SELECT id FROM keys WHERE id IN (%s) AND revoked_at IS NOT NULL" % marks, tuple(keys))}
        with self.lock:
            self.grants.update(grants)
        for s in streams:
            if s.key_id in dead:
                s.close()

    def tail_loop(self):
        # One loop for the whole hub (not per stream): picks up events written by other
        # processes (e.g. `ambient-hub.py send`) and admin changes from the CLI.
        while not self.stop.wait(1.0):
            try:
                self.poke()
                self.refresh_admin()
            except Exception as e:  # keep the hub alive
                log("tail: %s" % e)

    def prune_loop(self):
        while True:
            try:
                conn = self.conn()
                last = meta_get(conn, "last_prune")
                last_dt = parse_ts(last) if last else None
                if last_dt is None or (utcnow() - last_dt).total_seconds() >= 86400:
                    n = prune(conn)
                    log("prune: removed %d events past retention" % n)
            except Exception as e:
                log("prune: %s" % e)
            if self.stop.wait(3600):
                return

    def touch_key(self, key_id):
        now = time.monotonic()
        if now - self.last_used.get(key_id, -1e9) < 60:
            return
        self.last_used[key_id] = now
        try:
            self.conn().execute("UPDATE keys SET last_used_at = ? WHERE id = ?", (fmt_ts(utcnow()), key_id))
        except sqlite3.OperationalError:
            pass  # busy; not important


def log(msg):
    sys.stderr.write("%s ambient-hub: %s\n" % (fmt_ts(utcnow()), msg))
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# HTTP

def csv_param(qs, name):
    vals = qs.get(name)
    if not vals:
        return None
    items = [x.strip() for v in vals for x in v.split(",") if x.strip()]
    return items or None


def one_param(qs, name):
    vals = qs.get(name)
    return vals[-1] if vals else None


def resolve_source_filter(p, qs):
    """?source=a,b checked against the grant. Returns frozenset or None."""
    wanted = csv_param(qs, "source")
    if wanted is None:
        return None
    for slug in wanted:
        if not SLUG_RE.match(slug):
            raise bad("invalid_field", "source: '%s' is not a source slug ([a-z0-9-]{2,48})" % slug)
        if p.grant is not None and slug not in p.grant:
            raise ApiError(403, "source_not_granted", "this reader key is not granted source '%s'" % slug)
    return frozenset(wanted)


def grant_clause(p, where, params):
    if p.grant is not None:
        where.append("e.source IN (SELECT source FROM grants WHERE reader_id = ?)")
        params.append(p.reader_id)


class Handler(BaseHTTPRequestHandler):
    hub = None
    server_version = "ambient-hub/" + VERSION
    protocol_version = "HTTP/1.1"
    timeout = 75

    # -- plumbing

    def log_message(self, fmt, *args):
        if not self.hub.cfg.quiet:
            log("%s %s" % (self.address_string(), fmt % args))

    def send_json(self, status, obj, headers=None):
        body = json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if self.close_connection:
            self.send_header("Connection", "close")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def send_text(self, status, text, ctype):
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        length = self.headers.get("Content-Length")
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            self.close_connection = True
            raise ApiError(411, "length_required", "send the body with a Content-Length header")
        try:
            n = int(length) if length else 0
        except ValueError:
            self.close_connection = True
            raise bad("invalid_json", "bad Content-Length")
        self.body_read = True
        if n > MAX_BODY:
            if n <= 1024 * 1024:
                self.rfile.read(n)  # discard, so the client can read the answer
            else:
                self.close_connection = True
            raise ApiError(413, "too_large", "body is %d bytes; the limit is %d" % (n, MAX_BODY))
        return self.rfile.read(n) if n > 0 else b""

    def drain_body(self):
        try:
            self.read_body()
        except ApiError:
            pass

    def json_body(self):
        raw = self.read_body()
        try:
            return json.loads(raw.decode("utf-8")) if raw else None
        except (UnicodeDecodeError, ValueError) as e:
            raise bad("invalid_json", "body is not valid UTF-8 JSON: %s" % e)

    def base_url(self):
        public = self.hub.cfg.public_url
        if not public:
            proto = self.headers.get("X-Forwarded-Proto", "http").split(",")[0].strip()
            host = self.headers.get("X-Forwarded-Host") or self.headers.get("Host") or "localhost"
            public = "%s://%s" % (proto, host.split(",")[0].strip())
        return public.rstrip("/") + self.hub.cfg.base_path

    def principal(self, kind):
        p = authenticate(self.hub.conn(), self.headers.get("Authorization"))
        if p.kind != kind:
            raise ApiError(403, "wrong_key_kind", "this route needs a %s key; you sent a %s key" % (kind, p.kind))
        self.hub.touch_key(p.key_id)
        return p

    # -- dispatch

    def do_GET(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")

    def do_DELETE(self):
        self.dispatch("DELETE")

    def do_PUT(self):
        self.dispatch("PUT")

    def do_PATCH(self):
        self.dispatch("PATCH")

    def dispatch(self, method):
        parts = urlsplit(self.path)
        path, qs = parts.path, parse_qs(parts.query, keep_blank_values=True)
        base = self.hub.cfg.base_path
        self.body_read = False
        try:
            if path == "/healthz" and method == "GET":
                return self.send_text(200, "ok\n", "text/plain; charset=utf-8")
            if path != base and not path.startswith(base + "/"):
                raise ApiError(404, "not_found", "no such route; the base URL is %s" % self.base_url())
            rel = path[len(base):] or "/"
            routes = self.routes(rel)
            if routes is None:
                raise ApiError(404, "not_found", "no such route: %s" % rel)
            fn = routes.get(method)
            if fn is None:
                self.drain_body()
                raise ApiError(405, "method_not_allowed", "%s %s is not supported" % (method, rel),
                               {"Allow": ", ".join(sorted(routes))})
            return fn(qs)
        except ApiError as e:
            if not self.body_read and self.headers.get("Content-Length", "0") not in ("", "0"):
                self.close_connection = True  # unread body would corrupt the next request
            self.send_json(e.status, e.body(), e.headers)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except Exception as e:
            log("error on %s %s: %r" % (method, path, e))
            self.close_connection = True
            try:
                self.send_json(500, {"error": {"code": "internal", "message": "internal error"}})
            except Exception:
                pass

    def routes(self, rel):
        if rel == "/":
            return {"POST": self.r_publish, "GET": self.r_list}
        if rel == "/batch":
            return {"POST": self.r_batch}
        if rel == "/stream":
            return {"GET": self.r_stream}
        if rel == "/sources":
            return {"GET": self.r_sources}
        if rel == "/info":
            return {"GET": self.r_info}
        if rel == "/docs":
            return {"GET": self.r_docs}
        m = re.match(r"^/([^/]+)/dismiss$", rel)
        if m:
            eid = m.group(1)
            return {"POST": lambda qs: self.r_dismiss(eid, True),
                    "DELETE": lambda qs: self.r_dismiss(eid, False)}
        return None

    # -- publish

    def rate_check(self, p, cost):
        wait = self.hub.rate.take(p.key_id, cost)
        if wait:
            raise ApiError(429, "rate_limited",
                           "this key may publish %d requests per minute (burst %d); retry in %ds"
                           % (RATE_PER_MIN, RATE_BURST, wait), {"Retry-After": str(wait)})

    def r_publish(self, qs):
        try:
            p = self.principal("publish")
        except ApiError:
            self.drain_body()
            raise
        body = self.json_body()
        self.rate_check(p, 1)
        clean = validate_event(body, utcnow())
        (row, created), = publish_events(self.hub.conn(), p.source, [clean], utcnow())
        if created:
            self.hub.poke()
        self.send_json(201 if created else 200, event_json(row))

    def r_batch(self, qs):
        try:
            p = self.principal("publish")
        except ApiError:
            self.drain_body()
            raise
        body = self.json_body()
        if not isinstance(body, dict) or not isinstance(body.get("events"), list):
            raise bad("invalid_json", "body must be {\"events\": [ ... ]}")
        events = body["events"]
        extra = [k for k in body if k != "events"]
        if extra:
            raise bad("unknown_field", "%s: unknown field; the batch body has only \"events\"" % extra[0])
        if not 1 <= len(events) <= MAX_BATCH:
            raise bad("invalid_field", "events: send 1..%d events per batch" % MAX_BATCH)
        self.rate_check(p, int(math.ceil(len(events) / float(BATCH_EVENTS_PER_TOKEN))))
        now = utcnow()
        cleans = [validate_event(ev, now, "events[%d]." % i) for i, ev in enumerate(events)]
        results = publish_events(self.hub.conn(), p.source, cleans, now)
        created = any(c for _, c in results)
        if created:
            self.hub.poke()
        self.send_json(201 if created else 200, {"events": [event_json(r) for r, _ in results]})

    # -- read

    def r_list(self, qs):
        p = self.principal("reader")
        conn = self.hub.conn()
        where, params = [], [p.reader_id]
        grant_clause(p, where, params)
        latest_where, latest_params = list(where), list(params[1:])
        sources = resolve_source_filter(p, qs)
        if sources is not None:
            where.append("e.source IN (%s)" % ",".join("?" * len(sources)))
            params.extend(sorted(sources))
        types = csv_param(qs, "type")
        if types:
            for t in types:
                if not TYPE_RE.match(t):
                    raise bad("invalid_field", "type: '%s' is not an event type ([a-z0-9._-]{1,48})" % t)
            where.append("e.type IN (%s)" % ",".join("?" * len(types)))
            params.extend(types)
        smin = one_param(qs, "severity_min")
        if smin:
            if smin not in SEV_RANK:
                raise bad("invalid_field", "severity_min: must be one of %s" % " | ".join(SEVERITIES))
            where.append("e.severity >= ?")
            params.append(SEV_RANK[smin])
        q = one_param(qs, "q")
        if q:
            if len(q) > 200:
                raise bad("invalid_field", "q: at most 200 characters")
            like = "%" + q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
            where.append("(e.text LIKE ? ESCAPE '\\' OR e.detail LIKE ? ESCAPE '\\' OR e.subject LIKE ? ESCAPE '\\')")
            params.extend([like, like, like])
        after = parse_cursor(one_param(qs, "after"), "after")
        before = parse_cursor(one_param(qs, "before"), "before")
        if after is not None:
            where.append("e.seq > ?")
            params.append(after)
        if before is not None:
            where.append("e.seq < ?")
            params.append(before)
        sticky = one_param(qs, "sticky")
        if sticky:
            if sticky != "open":
                raise bad("invalid_field", "sticky: the only value is \"open\"")
            where.append("e.sticky = 1 AND d.dismissed_at IS NULL")
        lim = one_param(qs, "limit")
        if lim is None or lim == "":
            limit = LIST_DEFAULT
        else:
            if not lim.isdigit() or not 1 <= int(lim) <= LIST_MAX:
                raise bad("invalid_field", "limit: must be 1..%d" % LIST_MAX)
            limit = int(lim)
        order = "ASC" if after is not None else "DESC"
        sql = (EVENT_SELECT + ", d.dismissed_at FROM events e JOIN sources s ON s.slug = e.source "
               "LEFT JOIN dismissals d ON d.event_seq = e.seq AND d.reader_id = ?")
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY e.seq %s LIMIT ?" % order
        rows = conn.execute(sql, params + [limit + 1]).fetchall()
        more = len(rows) > limit
        rows = rows[:limit]
        next_before = str(rows[-1]["seq"]) if (more and order == "DESC") else None
        lsql = "SELECT MAX(e.seq) FROM events e"
        if latest_where:
            lsql += " WHERE " + " AND ".join(latest_where)
        latest = conn.execute(lsql, latest_params).fetchone()[0]
        self.send_json(200, {
            "events": [event_json(r, r["dismissed_at"]) for r in rows],
            "next_before": next_before,
            "latest_cursor": str(latest) if latest is not None else None,
        })

    def r_sources(self, qs):
        p = self.principal("reader")
        conn = self.hub.conn()
        since = fmt_ts(utcnow() - datetime.timedelta(days=1))
        out = []
        for slug in visible_sources(conn, p.grant):
            s = conn.execute(
                "SELECT s.slug, s.name, s.color, "
                "(SELECT MAX(received_at) FROM events WHERE source = s.slug) AS last_event_at, "
                "(SELECT COUNT(*) FROM events WHERE source = s.slug AND received_at >= ?) AS count_24h "
                "FROM sources s WHERE s.slug = ?", (since, slug)).fetchone()
            out.append({"slug": s["slug"], "name": s["name"], "color": s["color"],
                        "last_event_at": s["last_event_at"], "count_24h": s["count_24h"]})
        self.send_json(200, {"sources": out})

    def r_info(self, qs):
        p = authenticate(self.hub.conn(), self.headers.get("Authorization"))
        self.hub.touch_key(p.key_id)
        conn = self.hub.conn()
        info = {"protocol": PROTOCOL, "name": self.hub.cfg.name, "key": p.kind}
        if p.kind == "reader":
            info["reader"] = p.reader
            info["sources"] = visible_sources(conn, p.grant)
        else:
            info["sources"] = [p.source]
        info["features"] = list(FEATURES)
        info["docs"] = self.base_url() + "/docs"
        self.send_json(200, info)

    def r_docs(self, qs):
        self.send_text(200, render_docs(self.base_url(), self.hub.cfg.name), "text/markdown; charset=utf-8")

    def r_dismiss(self, eid, dismiss):
        p = self.principal("reader")
        self.drain_body()
        conn = self.hub.conn()
        if not EVENT_ID_RE.match(eid):
            raise ApiError(404, "not_found", "no event with id '%s'" % eid[:64])
        row = conn.execute("SELECT seq, source FROM events WHERE id = ?", (eid,)).fetchone()
        if row is None or (p.grant is not None and row["source"] not in p.grant):
            raise ApiError(404, "not_found", "no event with id '%s'" % eid)
        changed = False
        with tx(conn):
            cur = conn.execute("SELECT dismissed_at FROM dismissals WHERE reader_id = ? AND event_seq = ?",
                               (p.reader_id, row["seq"])).fetchone()
            if dismiss:
                if cur is None:
                    at = fmt_ts(utcnow())
                    conn.execute("INSERT INTO dismissals (reader_id, event_seq, dismissed_at) VALUES (?, ?, ?)",
                                 (p.reader_id, row["seq"], at))
                    changed = True
                else:
                    at = cur["dismissed_at"]
            else:
                at = None
                if cur is not None:
                    conn.execute("DELETE FROM dismissals WHERE reader_id = ? AND event_seq = ?",
                                 (p.reader_id, row["seq"]))
                    changed = True
        if changed:
            self.hub.emit_state(p.reader_id, row["source"], eid, at)
        self.send_json(200, {"id": eid, "dismissed_at": at})

    # -- stream

    def r_stream(self, qs):
        p = self.principal("reader")
        sources = resolve_source_filter(p, qs)
        header_cursor = self.headers.get("Last-Event-ID")
        # The header wins: EventSource reconnects keep the original ?after in the URL.
        after = parse_cursor(header_cursor.strip() if header_cursor else one_param(qs, "after"),
                             "Last-Event-ID" if header_cursor else "after")
        stream = Stream(p.key_id, p.reader_id, sources)
        self.hub.register(stream)
        self.close_connection = True
        tcp_keepalive(self.connection)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache, no-transform")
            self.send_header("X-Accel-Buffering", "no")
            self.send_header("Connection", "close")
            self.end_headers()
            w = self.wfile
            w.write(b": ambient/1 stream\nretry: 3000\n\n")
            last = after if after is not None else 0
            if after is not None:
                last = self.replay(p, sources, after, w)
            keepalive = self.hub.cfg.keepalive
            last_write = time.monotonic()
            while not self.hub.stop.is_set():
                try:
                    kind, seq, payload = stream.q.get(timeout=min(1.0, keepalive))
                except queue.Empty:
                    if self.client_gone():
                        break  # frees the stream slot now, not at the next keepalive
                    if time.monotonic() - last_write >= keepalive:
                        w.write(b": keepalive\n\n")
                        last_write = time.monotonic()
                    continue
                last_write = time.monotonic()
                if kind == "close":
                    break
                if kind == "event":
                    if seq <= last:
                        continue
                    last = seq
                    w.write(("id: %d\nevent: event\ndata: %s\n\n" % (seq, payload)).encode("utf-8"))
                else:
                    w.write(("event: state\ndata: %s\n\n" % payload).encode("utf-8"))
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            stream.closed = True
            self.hub.unregister(stream)

    def client_gone(self):
        try:
            readable, _, _ = select.select([self.connection], [], [], 0)
            if readable:
                return self.connection.recv(1, socket.MSG_PEEK) == b""
        except (OSError, ValueError):
            return True
        return False

    def replay(self, p, sources, after, w):
        conn = self.hub.conn()
        where, params = ["e.seq > ?"], [after]
        grant_clause(p, where, params)
        if sources is not None:
            where.append("e.source IN (%s)" % ",".join("?" * len(sources)))
            params.extend(sorted(sources))
        cond = " AND ".join(where)
        missed = conn.execute("SELECT COUNT(*) FROM events e WHERE " + cond, params).fetchone()[0]
        rows = conn.execute(
            EVENT_SELECT + ", d.dismissed_at FROM events e JOIN sources s ON s.slug = e.source "
            "LEFT JOIN dismissals d ON d.event_seq = e.seq AND d.reader_id = ? WHERE " + cond +
            " ORDER BY e.seq DESC LIMIT ?", [p.reader_id] + params + [REPLAY_MAX]).fetchall()
        rows.reverse()
        if missed > REPLAY_MAX:
            w.write(("event: gap\ndata: %s\n\n" % json.dumps({"missed": missed - REPLAY_MAX})).encode("utf-8"))
        last = after
        for r in rows:
            payload = json.dumps(event_json(r, r["dismissed_at"]), separators=(",", ":"), ensure_ascii=False)
            w.write(("id: %d\nevent: event\ndata: %s\n\n" % (r["seq"], payload)).encode("utf-8"))
            last = r["seq"]
        return last


def tcp_keepalive(sock):
    """Find peers that vanished without closing (a laptop that went to sleep) in about a minute,
    so their stream slots free up. Best effort; options differ per OS."""
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        idle = getattr(socket, "TCP_KEEPIDLE", None) or getattr(socket, "TCP_KEEPALIVE", None)
        if idle is not None:
            sock.setsockopt(socket.IPPROTO_TCP, idle, 30)
        if hasattr(socket, "TCP_KEEPINTVL"):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 10)
        if hasattr(socket, "TCP_KEEPCNT"):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)
    except OSError:
        pass


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 128


# ---------------------------------------------------------------------------
# /docs

DOCS = r'''# Publishing to {NAME}

This hub speaks the [Ambient protocol](https://github.com/SignedAdam/pager/blob/main/docs/protocol.md),
version 1. Programs post short events to it; people see them as one quiet line in Pager Ambient (or any
other reader). This page is the whole publisher's guide. It is written for humans and for coding agents.

## The two things you need

- **Base URL:** `{BASE}`
- **A publish key** (`ahp_…`) from the hub's admin. It is bound to one *source* (e.g. `deploys`). The source of
  every event you send comes from the key; never put `source` in the body.

Keep the key on the server side: environment variable, secret store, CI secret. Never put it in a browser bundle
or a mobile app; publish from your backend instead. The examples below read it from `AMBIENT_KEY`.

```sh
export AMBIENT_URL="{BASE}"
export AMBIENT_KEY="ahp_…"
```

## The rule: publishing must never hurt your program

An event is nice to have. Your program is not. Every publisher must:

1. use a timeout of **3 seconds or less**;
2. retry **at most 3 times**, with backoff (e.g. 0.5 s, 1 s, 2 s), and only on network errors, `429` and `5xx`;
3. then **drop the event** and move on. Never raise, never crash, never block the user, never queue forever;
4. send an `idempotency_key` so a retry after a timeout cannot create a duplicate.

Run the request in the background (a thread, a task, `&`). All examples below follow this rule.

## Publish one event

`POST {BASE}` with `Authorization: Bearer <key>` and a JSON body. Only `type` and `text` are required.

```sh
curl -sS --max-time 3 --retry 3 \
  -H "Authorization: Bearer $AMBIENT_KEY" \
  -H "Content-Type: application/json" \
  -d '{"type":"deploy.failed","severity":"error","text":"**api** failed on `main`","detail":"3 of 12 containers unhealthy","subject":"production","idempotency_key":"deploy-4812-failed"}' \
  "$AMBIENT_URL"
```

The hub stores the event, then answers **201** with it:

```json
{"id":"evt_9a1c0e5b7d2f4a68","cursor":"1734","source":"deploys","source_name":"Deploys","source_color":"#c7ff00",
 "type":"deploy.failed","severity":"error","text":"**api** failed on `main`","detail":"3 of 12 containers unhealthy",
 "subject":"production","url":null,"occurred_at":"2026-10-15T10:02:03Z","received_at":"2026-10-15T10:02:03Z",
 "display":{},"data":{}}
```

Sending the same `idempotency_key` again within 7 days answers **200** with the original event and stores nothing.

## Fields

| field | required | what |
|---|---|---|
| `type` | yes | what happened, `[a-z0-9._-]{1,48}`, e.g. `deploy.failed`, `backup.done`. Readers filter on it. |
| `text` | yes | the line people read, ≤ {MAX_TEXT} characters. Inline markdown only: `**bold**`, `*italic*`, `` `code` ``. No links, HTML or images. |
| `severity` | no | `debug`, `info` (default), `notice`, `warn`, `error`, `critical`. |
| `detail` | no | plain text, ≤ {MAX_DETAIL} characters. Shown in history, not in the line. |
| `subject` | no | short label, ≤ {MAX_SUBJECT} characters: the environment, host, customer, repo. |
| `url` | no | `http://` or `https://` link. Readers only open it when the user clicks it in history. |
| `occurred_at` | no | RFC 3339 time it happened. Default: now. Clamped to ±7 days of the hub's clock. |
| `display` | no | presentation hints, see below. |
| `data` | no | any JSON object ≤ 8 KB. Opaque to the hub; for your own tooling. |
| `idempotency_key` | no | ≤ {MAX_IDEM} characters, unique per event within your source. Strongly recommended. |

Unknown fields are rejected with **400** and a message that says what to fix.

## Severities

| severity | use it for |
|---|---|
| `debug` | noise you only want while working on the publisher itself |
| `info` | normal progress: a job finished, a PR merged |
| `notice` | worth a glance: a deploy went live, a payment arrived |
| `warn` | needs attention soon: disk at 85 %, a cron job ran late |
| `error` | something failed: a deploy, a backup, a test suite |
| `critical` | people should stop and look now: production down, data at risk |

Pick the lowest one that is honest. If everything is `error`, nothing is.

## Display hints

`display` is optional. These are suggestions; the reader's own settings always win.

| hint | values | meaning |
|---|---|---|
| `lifetime` | `1`..`86400` seconds, or `"sticky"` | how long the line stays. `"sticky"` stays until the reader dismisses it. |
| `layout` | `split` \| `inline` | source in its own column, or inline with the text |
| `effect` | `none` \| `blink` \| `flash` \| `highlight` \| `wave` \| `gradient` | attention effect |
| `target` | `emphasis` \| `message` | apply the effect to the `**emphasized**` part or the whole message |
| `period` | `0.5`..`10` seconds | one effect cycle |
| `color` | `"#rrggbb"` | accent for emphasized text |

Use `sticky` for things a person must act on, and nothing else. Effects are for `error` and `critical`.

## Examples in your language

Each one is a complete function you can paste. All of them: 3 s timeout, at most 3 retries with backoff, then drop.

### Shell (bash/zsh, needs `curl` and `jq`)

```sh
# ambient <type> <severity> <text> [subject]
ambient() {
  body=$(jq -nc --arg type "$1" --arg sev "$2" --arg text "$3" --arg subj "${4:-}" \
    --arg key "$(uuidgen 2>/dev/null || echo "$$-$RANDOM-$(date +%s)")" \
    '{type:$type, severity:$sev, text:$text, idempotency_key:$key} + (if $subj == "" then {} else {subject:$subj} end)') || return 0
  curl -sS -o /dev/null --max-time 3 --retry 3 --retry-delay 1 \
    -H "Authorization: Bearer $AMBIENT_KEY" -H "Content-Type: application/json" \
    --data "$body" "$AMBIENT_URL" >/dev/null 2>&1 &
}

ambient backup.done info "Nightly backup **done** in 4m12s" nas-01
```

`jq` builds the JSON so quotes in your text cannot break it. `&` keeps your script moving.

### JavaScript / TypeScript (Node 18+, Deno, Bun)

```js
const AMBIENT_URL = process.env.AMBIENT_URL ?? "{BASE}";
const AMBIENT_KEY = process.env.AMBIENT_KEY;

// Fire and forget: never throws, never awaits on your hot path.
export function ambient(event) {
  if (!AMBIENT_KEY) return;
  const body = JSON.stringify({ idempotency_key: crypto.randomUUID(), ...event });
  (async () => {
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        const res = await fetch(AMBIENT_URL, {
          method: "POST",
          headers: { Authorization: `Bearer ${AMBIENT_KEY}`, "Content-Type": "application/json" },
          body,
          signal: AbortSignal.timeout(3000),
        });
        if (res.status < 500 && res.status !== 429) return; // stored, duplicate, or our own mistake
      } catch {}
      if (attempt < 3) await new Promise((r) => setTimeout(r, 500 * 2 ** attempt));
    }
  })().catch(() => {});
}

ambient({ type: "deploy.succeeded", severity: "notice", text: "**web** is live on production", subject: "v2.14.0" });
```

### Python (3.8+, standard library only)

```python
import json, os, threading, time, urllib.error, urllib.request, uuid

AMBIENT_URL = os.environ.get("AMBIENT_URL", "{BASE}")
AMBIENT_KEY = os.environ.get("AMBIENT_KEY", "")

def ambient(type, text, severity="info", **fields):
    """Fire and forget. Never raises, never blocks the caller."""
    if not AMBIENT_KEY:
        return
    body = json.dumps({"type": type, "text": text, "severity": severity,
                       "idempotency_key": uuid.uuid4().hex, **fields}).encode()

    def send():
        for attempt in range(4):
            try:
                req = urllib.request.Request(AMBIENT_URL, data=body, method="POST", headers={
                    "Authorization": "Bearer " + AMBIENT_KEY, "Content-Type": "application/json"})
                urllib.request.urlopen(req, timeout=3).close()
                return
            except urllib.error.HTTPError as e:
                if e.code < 500 and e.code != 429:
                    return  # 4xx: retrying will not help
            except Exception:
                pass
            if attempt < 3:
                time.sleep(0.5 * 2 ** attempt)

    threading.Thread(target=send, daemon=True).start()

ambient("payment.received", "**€1,200** from Acme GmbH", severity="notice", subject="invoice 2026-114")
```

### Go

```go
package ambient

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"time"
)

var client = &http.Client{Timeout: 3 * time.Second}

// Publish sends an event in the background. It never blocks and never fails the caller.
func Publish(ev map[string]any) {
	key := os.Getenv("AMBIENT_KEY")
	url := os.Getenv("AMBIENT_URL")
	if url == "" {
		url = "{BASE}"
	}
	if key == "" {
		return
	}
	if _, ok := ev["idempotency_key"]; !ok {
		b := make([]byte, 16)
		rand.Read(b)
		ev["idempotency_key"] = hex.EncodeToString(b)
	}
	body, err := json.Marshal(ev)
	if err != nil {
		return
	}
	go func() {
		for attempt := 0; attempt < 4; attempt++ {
			req, _ := http.NewRequest("POST", url, bytes.NewReader(body))
			req.Header.Set("Authorization", "Bearer "+key)
			req.Header.Set("Content-Type", "application/json")
			if res, err := client.Do(req); err == nil {
				io.Copy(io.Discard, res.Body)
				res.Body.Close()
				if res.StatusCode < 500 && res.StatusCode != 429 {
					return
				}
			}
			if attempt < 3 {
				time.Sleep(time.Duration(500<<attempt) * time.Millisecond)
			}
		}
	}()
}

// ambient.Publish(map[string]any{"type": "ci.passed", "text": "All **412 checks** passed", "subject": "main"})
```

### Swift (macOS 12+ / iOS 15+)

```swift
import Foundation

enum Ambient {
    static let url = URL(string: ProcessInfo.processInfo.environment["AMBIENT_URL"] ?? "{BASE}")!
    static let key = ProcessInfo.processInfo.environment["AMBIENT_KEY"] ?? ""

    /// Fire and forget. Never throws, never blocks the caller.
    static func publish(_ event: [String: Any]) {
        guard !key.isEmpty else { return }
        var event = event
        if event["idempotency_key"] == nil { event["idempotency_key"] = UUID().uuidString }
        guard let body = try? JSONSerialization.data(withJSONObject: event) else { return }
        Task.detached(priority: .background) {
            for attempt in 0..<4 {
                var req = URLRequest(url: url, timeoutInterval: 3)
                req.httpMethod = "POST"
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = body
                if let (_, res) = try? await URLSession.shared.data(for: req),
                   let code = (res as? HTTPURLResponse)?.statusCode, code < 500, code != 429 { return }
                if attempt < 3 { try? await Task.sleep(nanoseconds: 500_000_000 << UInt64(attempt)) }
            }
        }
    }
}

// Ambient.publish(["type": "build.finished", "text": "Archive **ready** in 3m11s", "subject": "Pager 1.4.0"])
```

## Publish many at once

`POST {BASE}/batch` with `{"events": [ … ]}`, 1..{MAX_BATCH} events. The hub answers `{"events": [ … ]}` in the
same order. The batch is all or nothing: one invalid event rejects the batch with 400, and the message names it
(`events[3].text: …`). Each event may carry its own `idempotency_key`.

## Example events

```json
{"type":"deploy.failed","severity":"error","text":"**api** failed on `main`","detail":"3 of 12 containers unhealthy; traffic stays on the previous revision","subject":"production","url":"https://ci.example.com/runs/4812","display":{"lifetime":"sticky","effect":"flash","target":"emphasis"},"idempotency_key":"deploy-4812"}
{"type":"deploy.succeeded","severity":"notice","text":"**web** is live","subject":"v2.14.0","idempotency_key":"deploy-4813"}
{"type":"ci.passed","severity":"info","text":"All **412 checks** passed in `3m11s`","subject":"main","display":{"lifetime":20}}
{"type":"backup.done","severity":"info","text":"Nightly backup done, **18.4 GB**","subject":"nas-01","occurred_at":"2026-10-15T03:00:12Z"}
{"type":"disk.high","severity":"warn","text":"Disk at **87 %** on `db-2`","detail":"/var/lib/postgresql grew 9 GB in 24 h","subject":"db-2"}
{"type":"payment.received","severity":"notice","text":"**€1,200** from Acme GmbH","subject":"invoice 2026-114","data":{"invoice":"2026-114","amount_cents":120000}}
{"type":"incident.opened","severity":"critical","text":"**Checkout is down**","detail":"5xx rate 41 % since 10:02","subject":"production","url":"https://status.example.com/incidents/77","display":{"lifetime":"sticky","effect":"blink","color":"#ff5f57","period":1}}
{"type":"pr.review_requested","severity":"info","text":"Review requested: *Add retry to the uploader*","subject":"pager#212","url":"https://github.com/acme/app/pull/212"}
{"type":"cron.late","severity":"warn","text":"`invoice-sync` ran **41 min** late","subject":"worker-1"}
{"type":"agent.done","severity":"notice","text":"Agent finished: *migrate settings to v2*, tests green","subject":"claude-code","display":{"lifetime":60,"layout":"inline"}}
```

## Answers and errors

| status | meaning | what to do |
|---|---|---|
| 201 | stored | done |
| 200 | duplicate `idempotency_key`; this is the original event | done |
| 400 | invalid event; `error.message` says what to fix | fix the code, do not retry |
| 401 | missing, unknown or revoked key | ask the hub's admin |
| 403 | wrong key kind (`wrong_key_kind`), or the source is archived | ask the hub's admin |
| 413 | body over {MAX_BODY_KB} KB | send less |
| 429 | rate limited; wait `Retry-After` seconds | retry later or drop |
| 5xx | hub trouble | retry with backoff, then drop |

Errors look like `{"error":{"code":"invalid_field","message":"text: 341 characters; the limit is 300 (put the rest in detail)"}}`.

## Limits on this hub

- Body: {MAX_BODY_KB} KB. `text` {MAX_TEXT}, `detail` {MAX_DETAIL}, `subject` {MAX_SUBJECT} characters; `data` 8 KB.
- Publishing: {RATE} requests per minute per key, bursts of {BURST}. A batch costs one request per
  {PER_TOKEN} events (rounded up).
- Idempotency keys are remembered for 7 days per source.
- Events are kept for the source's retention period (90 days unless the admin set another).
- Readers: {MAX_STREAMS} concurrent streams per reader key; replay of at most {REPLAY} events on resume.

## Reading (for client authors)

Reader keys (`ahr_…`) are separate from publish keys and cannot publish. Everything a reader sees is limited to
the sources the admin granted it.

- `GET {BASE}/info`: validate a key; shows the hub name and the sources it can see.
- `GET {BASE}/sources`: sources with `last_event_at` and `count_24h`.
- `GET {BASE}/?limit=50`: newest first. Filters: `source=a,b`, `type=`, `severity_min=warn`, `q=` (text search),
  `before=<cursor>` (page back with `next_before`), `after=<cursor>` (oldest first, for catch-up; page forward with
  the last cursor until fewer than `limit` come back), `sticky=open`.
- `GET {BASE}/stream`: Server-Sent Events. Resume with `Last-Event-ID` or `?after=<cursor>`. Frames: `event`,
  `state` (your own dismissals from another device), `gap` (`{"missed": n}`: more than {REPLAY} events were
  missed; `n` were skipped). A `: keepalive` comment arrives every {KEEPALIVE} s; reconnect after 60 s of silence.
- `POST {BASE}/<id>/dismiss` and `DELETE {BASE}/<id>/dismiss`: your dismissal, per reader, not global.

```sh
curl -N -H "Authorization: Bearer $AMBIENT_READER_KEY" "{BASE}/stream"
```

The full contract is the [Ambient protocol](https://github.com/SignedAdam/pager/blob/main/docs/protocol.md).
'''


def render_docs(base, name):
    subs = {
        "{BASE}": base, "{NAME}": name, "{MAX_TEXT}": str(MAX_TEXT), "{MAX_DETAIL}": str(MAX_DETAIL),
        "{MAX_SUBJECT}": str(MAX_SUBJECT), "{MAX_IDEM}": str(MAX_IDEMPOTENCY_KEY), "{MAX_BATCH}": str(MAX_BATCH),
        "{MAX_BODY_KB}": str(MAX_BODY // 1024), "{RATE}": str(RATE_PER_MIN), "{BURST}": str(RATE_BURST),
        "{PER_TOKEN}": str(BATCH_EVENTS_PER_TOKEN), "{MAX_STREAMS}": str(MAX_STREAMS_PER_KEY),
        "{REPLAY}": str(REPLAY_MAX), "{KEEPALIVE}": "%g" % DEFAULT_KEEPALIVE,
    }
    out = DOCS
    for k, v in subs.items():
        out = out.replace(k, v)
    return out


# ---------------------------------------------------------------------------
# serve

class Config:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def parse_listen(value):
    if value.startswith("["):
        host, _, port = value[1:].partition("]:")
    else:
        host, _, port = value.rpartition(":")
    if not port.isdigit():
        raise SystemExit("ambient-hub: --listen must look like 0.0.0.0:8790")
    return host or "0.0.0.0", int(port)


def cmd_serve(a):
    base_path = "/" + a.base_path.strip("/") if a.base_path.strip("/") else ""
    if not base_path:
        raise SystemExit("ambient-hub: --base-path must not be empty (default /v1/events)")
    cfg = Config(db=a.db, public_url=(a.public_url or "").rstrip("/"), base_path=base_path,
                 name=a.name, quiet=a.quiet, keepalive=a.keepalive)
    open_db(cfg.db).close()
    hub = Hub(cfg)
    handler = type("BoundHandler", (Handler,), {"hub": hub})
    host, port = parse_listen(a.listen)
    if ":" in host:
        Server.address_family = socket.AF_INET6
    httpd = Server((host, port), handler)
    bound = httpd.server_address
    shown = cfg.public_url or "http://%s:%d" % ("127.0.0.1" if host in ("0.0.0.0", "") else host, bound[1])
    threading.Thread(target=hub.tail_loop, name="tail", daemon=True).start()
    threading.Thread(target=hub.prune_loop, name="prune", daemon=True).start()

    def on_term(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, on_term)
    log("%s %s listening on %s:%d" % (cfg.name, VERSION, host, bound[1]))
    print("ambient-hub listening on %s:%d, base URL %s%s" % (host, bound[1], shown, base_path), flush=True)
    try:
        httpd.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        hub.stop.set()
        hub.close_all()
        httpd.server_close()
        log("stopped")


# ---------------------------------------------------------------------------
# admin CLI (works on the database directly, also while the server runs)

def admin_conn(a):
    if not a.db:
        raise SystemExit("ambient-hub: set --db or AMBIENT_HUB_DB")
    return open_db(a.db)


def check_color(c):
    if c is None:
        return None
    if not COLOR_RE.match(c):
        raise AdminError("--color must be a hex color like #c7ff00")
    return normalize_color(c)


def table(rows, headers):
    rows = [[("" if v is None else str(v)) for v in r] for r in rows]
    widths = [max([len(h)] + [len(r[i]) for r in rows]) for i, h in enumerate(headers)]
    line = lambda r: "  ".join(v.ljust(widths[i]) for i, v in enumerate(r)).rstrip()
    print(line(headers))
    for r in rows:
        print(line(r))


def cmd_source_add(a):
    conn = admin_conn(a)
    if not SLUG_RE.match(a.slug):
        raise AdminError("slug must be 2-48 characters of a-z, 0-9 and -")
    if a.retention_days < 0:
        raise AdminError("--retention-days must be 0 (keep forever) or more")
    color = check_color(a.color)
    with tx(conn):
        if conn.execute("SELECT 1 FROM sources WHERE slug = ?", (a.slug,)).fetchone():
            raise AdminError("source '%s' already exists (use `source update`)" % a.slug)
        conn.execute("INSERT INTO sources (slug, name, color, retention_days, created_at) VALUES (?, ?, ?, ?, ?)",
                     (a.slug, a.name or a.slug, color, a.retention_days, fmt_ts(utcnow())))
        bump_admin_version(conn)
    print("source %s added. Next: ambient-hub.py key publish %s --label <who-publishes>" % (a.slug, a.slug))


def cmd_source_update(a):
    conn = admin_conn(a)
    with tx(conn):
        if not conn.execute("SELECT 1 FROM sources WHERE slug = ?", (a.slug,)).fetchone():
            raise AdminError("no source '%s'" % a.slug)
        if a.name:
            conn.execute("UPDATE sources SET name = ? WHERE slug = ?", (a.name, a.slug))
        if a.color is not None:
            conn.execute("UPDATE sources SET color = ? WHERE slug = ?", (check_color(a.color) if a.color else None, a.slug))
        if a.retention_days is not None:
            conn.execute("UPDATE sources SET retention_days = ? WHERE slug = ?", (a.retention_days, a.slug))
        if a.unarchive:
            conn.execute("UPDATE sources SET archived_at = NULL WHERE slug = ?", (a.slug,))
        bump_admin_version(conn)
    print("source %s updated" % a.slug)


def cmd_source_list(a):
    conn = admin_conn(a)
    rows = conn.execute(
        "SELECT s.slug, s.name, s.color, s.retention_days, s.archived_at, "
        "(SELECT COUNT(*) FROM events WHERE source = s.slug) AS n, "
        "(SELECT MAX(received_at) FROM events WHERE source = s.slug) AS last "
        "FROM sources s ORDER BY s.slug").fetchall()
    table([(r["slug"], r["name"], r["color"] or "-", "%sd" % r["retention_days"] if r["retention_days"] else "forever",
            r["n"], r["last"] or "-", "archived" if r["archived_at"] else "active") for r in rows],
          ["SLUG", "NAME", "COLOR", "RETENTION", "EVENTS", "LAST EVENT", "STATUS"])


def cmd_source_archive(a):
    conn = admin_conn(a)
    with tx(conn):
        n = conn.execute("UPDATE sources SET archived_at = ? WHERE slug = ? AND archived_at IS NULL",
                         (fmt_ts(utcnow()), a.slug)).rowcount
        if not n:
            raise AdminError("no active source '%s'" % a.slug)
        bump_admin_version(conn)
    print("source %s archived: its publish keys now get 403 and readers no longer list it. "
          "Its events stay until retention removes them." % a.slug)


def insert_key(conn, kind, label, source=None, reader_id=None):
    key = new_key(kind)
    conn.execute("INSERT INTO keys (prefix, hash, kind, label, source, reader_id, created_at) "
                 "VALUES (?, ?, ?, ?, ?, ?, ?)",
                 (key[:KEY_SHOWN], hash_key(key), kind, label, source, reader_id, fmt_ts(utcnow())))
    return key


def show_key(key, what):
    sys.stderr.write("%s\nThis is the only time the key is shown. Store it now; the hub keeps only a hash.\n" % what)
    base = os.environ.get("AMBIENT_HUB_PUBLIC_URL")
    if base:
        bp = os.environ.get("AMBIENT_HUB_BASE_PATH", "/v1/events")
        sys.stderr.write("Base URL: %s/%s\n" % (base.rstrip("/"), bp.strip("/")))
    sys.stderr.flush()
    print(key, flush=True)


def parse_sources_arg(conn, value):
    slugs = [s.strip() for s in value.split(",") if s.strip()]
    if not slugs:
        raise AdminError("--sources needs at least one slug (or use --all)")
    for s in slugs:
        if not conn.execute("SELECT 1 FROM sources WHERE slug = ?", (s,)).fetchone():
            raise AdminError("no source '%s' (see `source list`)" % s)
    return slugs


def set_grant(conn, reader_id, all_sources, slugs):
    conn.execute("UPDATE readers SET all_sources = ? WHERE id = ?", (1 if all_sources else 0, reader_id))
    conn.execute("DELETE FROM grants WHERE reader_id = ?", (reader_id,))
    for s in slugs or []:
        conn.execute("INSERT INTO grants (reader_id, source) VALUES (?, ?)", (reader_id, s))


def grant_text(conn, reader_id):
    g = load_grant(conn, reader_id)
    return "all sources" if g is None else (", ".join(sorted(g)) or "nothing")


def cmd_key_publish(a):
    conn = admin_conn(a)
    with tx(conn):
        s = conn.execute("SELECT archived_at FROM sources WHERE slug = ?", (a.source,)).fetchone()
        if s is None:
            raise AdminError("no source '%s' (add it with `source add`)" % a.source)
        if s["archived_at"]:
            raise AdminError("source '%s' is archived" % a.source)
        key = insert_key(conn, "publish", a.label, source=a.source)
        bump_admin_version(conn)
    show_key(key, "Publish key for source '%s'%s." % (a.source, " (%s)" % a.label if a.label else ""))


def cmd_key_reader(a):
    conn = admin_conn(a)
    with tx(conn):
        slugs = parse_sources_arg(conn, a.sources) if a.sources else None
        r = conn.execute("SELECT id FROM readers WHERE label = ?", (a.label,)).fetchone()
        if r is None:
            if not a.all and slugs is None:
                raise AdminError("a new reader needs a grant: --sources a,b or --all")
            rid = conn.execute("INSERT INTO readers (label, all_sources, created_at) VALUES (?, 0, ?)",
                               (a.label, fmt_ts(utcnow()))).lastrowid
            set_grant(conn, rid, a.all, slugs)
            note = "New reader '%s'" % a.label
        else:
            rid = r["id"]
            if a.all or slugs is not None:
                set_grant(conn, rid, a.all, slugs)
            note = "Another key for existing reader '%s' (shares its dismiss state)" % a.label
        key = insert_key(conn, "reader", a.label, reader_id=rid)
        bump_admin_version(conn)
        sees = grant_text(conn, rid)
    show_key(key, "%s, sees: %s." % (note, sees))


def cmd_key_list(a):
    conn = admin_conn(a)
    rows = conn.execute(
        "SELECT k.*, r.label AS reader FROM keys k LEFT JOIN readers r ON r.id = k.reader_id "
        "ORDER BY k.revoked_at IS NOT NULL, k.kind, k.created_at").fetchall()
    out = []
    for r in rows:
        if r["kind"] == "publish":
            scope = "publish to " + r["source"]
        else:
            scope = "read " + grant_text(conn, r["reader_id"])
        out.append((r["prefix"] + "…", r["kind"], r["reader"] or r["label"] or "-", scope,
                    r["created_at"][:10], (r["last_used_at"] or "never")[:16].replace("T", " "),
                    "revoked" if r["revoked_at"] else "active"))
    table(out, ["KEY", "KIND", "LABEL", "SCOPE", "CREATED", "LAST USED", "STATUS"])


def find_key(conn, prefix):
    prefix = prefix.rstrip("…").rstrip(".")
    if len(prefix) < 8:
        raise AdminError("give at least the first 8 characters of the key, as shown by `key list`")
    rows = conn.execute("SELECT * FROM keys WHERE (prefix LIKE ? || '%' OR ? LIKE prefix || '%') "
                        "AND revoked_at IS NULL", (prefix, prefix)).fetchall()
    rows = [r for r in rows if r["prefix"].startswith(prefix) or prefix.startswith(r["prefix"])]
    if len(prefix) > KEY_SHOWN:  # a full key: match the hash exactly
        rows = [r for r in rows if r["hash"] == hash_key(prefix)] or rows
    if not rows:
        raise AdminError("no active key starts with '%s'" % prefix)
    if len(rows) > 1:
        raise AdminError("'%s' matches %d keys; give more characters" % (prefix, len(rows)))
    return rows[0]


def cmd_key_revoke(a):
    conn = admin_conn(a)
    with tx(conn):
        k = find_key(conn, a.prefix)
        conn.execute("UPDATE keys SET revoked_at = ? WHERE id = ?", (fmt_ts(utcnow()), k["id"]))
        bump_admin_version(conn)
    print("revoked %s… (%s). Requests with it now get 401; its open streams close within a second."
          % (k["prefix"], k["kind"]))


def cmd_key_rotate(a):
    conn = admin_conn(a)
    with tx(conn):
        k = find_key(conn, a.prefix)
        key = insert_key(conn, k["kind"], k["label"], source=k["source"], reader_id=k["reader_id"])
        conn.execute("UPDATE keys SET revoked_at = ? WHERE id = ?", (fmt_ts(utcnow()), k["id"]))
        bump_admin_version(conn)
    what = ("publish key for source '%s'" % k["source"]) if k["kind"] == "publish" else \
        ("reader key for '%s' (same reader: dismiss state and grant carry over)" % k["label"])
    show_key(key, "Rotated %s… -> new %s. The old key is revoked." % (k["prefix"], what))


def cmd_key_grant(a):
    conn = admin_conn(a)
    if not a.all and not a.sources:
        raise AdminError("give --sources a,b or --all")
    with tx(conn):
        r = conn.execute("SELECT id FROM readers WHERE label = ?", (a.reader,)).fetchone()
        if r is None:
            raise AdminError("no reader '%s' (create it with `key reader`)" % a.reader)
        set_grant(conn, r["id"], a.all, parse_sources_arg(conn, a.sources) if a.sources else None)
        bump_admin_version(conn)
        sees = grant_text(conn, r["id"])
    print("reader %s now sees: %s (applies to its open streams within a second)" % (a.reader, sees))


def cmd_send(a):
    conn = admin_conn(a)
    body = {"type": a.type, "text": a.text, "severity": a.severity}
    for k in ("detail", "subject", "url", "idempotency_key"):
        if getattr(a, k):
            body[k] = getattr(a, k)
    if a.sticky:
        body["display"] = {"lifetime": "sticky"}
    if a.data:
        body["data"] = json.loads(a.data)
    if not conn.execute("SELECT 1 FROM sources WHERE slug = ?", (a.source,)).fetchone():
        raise AdminError("no source '%s'" % a.source)
    try:
        clean = validate_event(body, utcnow())
        (row, created), = publish_events(conn, a.source, [clean], utcnow())
    except ApiError as e:
        raise AdminError(e.message)
    print(json.dumps(event_json(row), ensure_ascii=False))


def cmd_prune(a):
    conn = admin_conn(a)
    n = prune(conn)
    print("removed %d events past retention" % n)


def build_parser():
    env = os.environ.get
    p = argparse.ArgumentParser(prog="ambient-hub.py",
                                description="Reference hub for the Ambient protocol (ambient/1).")
    p.add_argument("--version", action="version", version="ambient-hub " + VERSION)
    sub = p.add_subparsers(dest="cmd", metavar="command")
    sub.required = True

    def with_db(sp):
        sp.add_argument("--db", default=env("AMBIENT_HUB_DB", "./hub.db"),
                        help="SQLite path (env AMBIENT_HUB_DB, default ./hub.db)")
        return sp

    s = with_db(sub.add_parser("serve", help="run the hub"))
    s.add_argument("--listen", default=env("AMBIENT_HUB_LISTEN", "127.0.0.1:8790"),
                   help="host:port (env AMBIENT_HUB_LISTEN, default 127.0.0.1:8790; port 0 = random)")
    s.add_argument("--public-url", default=env("AMBIENT_HUB_PUBLIC_URL", ""),
                   help="how the world reaches this server, e.g. https://hub.example.com (env AMBIENT_HUB_PUBLIC_URL)")
    s.add_argument("--base-path", default=env("AMBIENT_HUB_BASE_PATH", "/v1/events"),
                   help="path of the base URL (env AMBIENT_HUB_BASE_PATH, default /v1/events)")
    s.add_argument("--name", default=env("AMBIENT_HUB_NAME", "Ambient hub"),
                   help="hub name shown to clients (env AMBIENT_HUB_NAME)")
    s.add_argument("--keepalive", type=float, default=float(env("AMBIENT_HUB_KEEPALIVE", DEFAULT_KEEPALIVE)),
                   help=argparse.SUPPRESS)
    s.add_argument("--quiet", action="store_true", default=env("AMBIENT_HUB_QUIET", "") not in ("", "0"),
                   help="no access log (env AMBIENT_HUB_QUIET=1)")
    s.set_defaults(fn=cmd_serve)

    src = sub.add_parser("source", help="manage sources").add_subparsers(dest="sub", metavar="action")
    src.required = True
    x = with_db(src.add_parser("add", help="add a source"))
    x.add_argument("slug")
    x.add_argument("--name", help="display name (default: the slug)")
    x.add_argument("--color", help="#rrggbb")
    x.add_argument("--retention-days", type=int, default=DEFAULT_RETENTION_DAYS, help="0 = forever (default 90)")
    x.set_defaults(fn=cmd_source_add)
    x = with_db(src.add_parser("update", help="change name, color, retention, or unarchive"))
    x.add_argument("slug")
    x.add_argument("--name")
    x.add_argument("--color", help='#rrggbb, or "" to clear')
    x.add_argument("--retention-days", type=int)
    x.add_argument("--unarchive", action="store_true")
    x.set_defaults(fn=cmd_source_update)
    with_db(src.add_parser("list", help="list sources")).set_defaults(fn=cmd_source_list)
    x = with_db(src.add_parser("archive", help="stop accepting events for a source; hide it from readers"))
    x.add_argument("slug")
    x.set_defaults(fn=cmd_source_archive)

    key = sub.add_parser("key", help="manage keys and grants").add_subparsers(dest="sub", metavar="action")
    key.required = True
    x = with_db(key.add_parser("publish", help="new publish key for a source (printed once)"))
    x.add_argument("source")
    x.add_argument("--label", help="who uses it, e.g. ci or billing-service")
    x.set_defaults(fn=cmd_key_publish)
    x = with_db(key.add_parser("reader", help="new reader key (printed once); creates the reader if new"))
    x.add_argument("label", help="the reader: a person or device, e.g. alice or adam-mac")
    g = x.add_mutually_exclusive_group()
    g.add_argument("--sources", help="comma-separated source slugs this reader may see")
    g.add_argument("--all", action="store_true", help="may see every source, including future ones")
    x.set_defaults(fn=cmd_key_reader)
    with_db(key.add_parser("list", help="list keys (never shows the secret part)")).set_defaults(fn=cmd_key_list)
    x = with_db(key.add_parser("revoke", help="revoke a key by its prefix"))
    x.add_argument("prefix")
    x.set_defaults(fn=cmd_key_revoke)
    x = with_db(key.add_parser("rotate", help="issue a replacement key for the same reader/source, revoke the old"))
    x.add_argument("prefix")
    x.set_defaults(fn=cmd_key_rotate)
    x = with_db(key.add_parser("grant", help="set which sources a reader may see (replaces its grant)"))
    x.add_argument("reader")
    g = x.add_mutually_exclusive_group()
    g.add_argument("--sources")
    g.add_argument("--all", action="store_true")
    x.set_defaults(fn=cmd_key_grant)

    x = with_db(sub.add_parser("send", help="publish a test event as a source (no key needed)"))
    x.add_argument("source")
    x.add_argument("--text", required=True)
    x.add_argument("--type", default="hub.test")
    x.add_argument("--severity", default="info", choices=SEVERITIES)
    x.add_argument("--detail")
    x.add_argument("--subject")
    x.add_argument("--url")
    x.add_argument("--idempotency-key")
    x.add_argument("--sticky", action="store_true")
    x.add_argument("--data", help="JSON object")
    x.set_defaults(fn=cmd_send)

    with_db(sub.add_parser("prune", help="delete events past their source's retention now")).set_defaults(fn=cmd_prune)
    return p


def main(argv=None):
    a = build_parser().parse_args(argv)
    try:
        a.fn(a)
    except AdminError as e:
        sys.stderr.write("ambient-hub: %s\n" % e)
        return 1
    except sqlite3.OperationalError as e:
        sys.stderr.write("ambient-hub: database error: %s\n" % e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
