#!/usr/bin/env python3
"""Tests for the reference hub: runs conformance.py against a fresh hub, then checks the hub-specific parts
(admin CLI, revocation and grant changes on open streams, rotation, archive, prune, gap, keepalive).

    python3 hub/test_hub.py            # ~30 s
    python3 hub/test_hub.py -v

Standard library only. Starts its own hubs on random ports with temporary databases and stops them.
"""

import http.client
import importlib.util
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HUB = os.path.join(HERE, "ambient-hub.py")
CONFORMANCE = os.path.join(HERE, "conformance.py")
PY = sys.executable

sys.path.insert(0, HERE)
import conformance as conf  # noqa: E402

_spec = importlib.util.spec_from_file_location("ambient_hub", HUB)
hubmod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hubmod)


def cli(db, *args, ok=True):
    p = subprocess.run([PY, HUB] + list(args) + ["--db", db], capture_output=True, text=True, timeout=30)
    if ok and p.returncode != 0:
        raise AssertionError("cli %s failed: %s" % (args, p.stderr))
    return p


class HubProcess:
    def __init__(self, db, *extra):
        self.db = db
        self.proc = subprocess.Popen([PY, HUB, "serve", "--db", db, "--listen", "127.0.0.1:0", "--quiet"] + list(extra),
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = self.proc.stdout.readline()
        m = re.search(r"listening on 127\.0\.0\.1:(\d+), base URL https?://[^/]+(\S+)", line)
        if not m:
            self.stop()
            raise RuntimeError("hub did not start: %r %s" % (line, self.proc.stderr.read()))
        self.base = "http://127.0.0.1:%s%s" % (m.group(1), m.group(2))
        self.client = conf.Client(self.base)

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.proc.stdout.close()
        self.proc.stderr.close()


def open_stream(client, key, params=None, last_event_id=None):
    """Open a stream; earlier tests' closed streams free their slots within ~1 s."""
    for _ in range(30):
        s = conf.SSE(client, key, params, last_event_id)
        if s.status != 429:
            return s
        time.sleep(0.2)
    return s


class HubTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.db = os.path.join(cls.tmp.name, "hub.db")
        cli(cls.db, "source", "add", "deploys", "--name", "Deploys", "--color", "#c7ff00")
        cli(cls.db, "source", "add", "billing", "--name", "Billing")
        cli(cls.db, "source", "add", "old", "--name", "Old", "--retention-days", "1")
        cls.P = cli(cls.db, "key", "publish", "deploys", "--label", "ci").stdout.strip()
        cls.PB = cli(cls.db, "key", "publish", "billing").stdout.strip()
        cls.R = cli(cls.db, "key", "reader", "alice", "--all").stdout.strip()
        cls.R2 = cli(cls.db, "key", "reader", "bob", "--sources", "deploys,billing").stdout.strip()
        cls.R3 = cli(cls.db, "key", "reader", "carol", "--sources", "billing").stdout.strip()
        cls.hub = HubProcess(cls.db, "--keepalive", "1")
        cls.c = cls.hub.client

    @classmethod
    def tearDownClass(cls):
        cls.hub.stop()
        cls.tmp.cleanup()

    def publish(self, key, **body):
        body.setdefault("type", "test.event")
        body.setdefault("text", "hello")
        r = self.c.req("POST", "/", key, body=body)
        self.assertIn(r.status, (200, 201), r.short())
        return r.json

    # --- the black-box suite -------------------------------------------------

    def test_00_conformance(self):
        p = subprocess.run([PY, CONFORMANCE, self.hub.base, "--publish-key", self.P, "--reader-key", self.R,
                            "--reader-key-2", self.R2, "--restricted-reader", self.R3, "--no-color"],
                           capture_output=True, text=True, timeout=300)
        sys.stderr.write("\n" + p.stdout.strip().splitlines()[-1] + "\n")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    # --- keys ----------------------------------------------------------------

    def test_keys_are_prefixed_and_stored_hashed(self):
        self.assertTrue(self.P.startswith("ahp_") and len(self.P) == 36)
        self.assertTrue(self.R.startswith("ahr_") and len(self.R) == 36)
        conn = sqlite3.connect(self.db)
        dump = "\n".join(conn.iterdump())
        conn.close()
        for k in (self.P, self.R):
            self.assertNotIn(k, dump)
            self.assertNotIn(k[KEY_SECRET:], dump)
        listing = cli(self.db, "key", "list").stdout
        self.assertNotIn(self.P, listing)
        self.assertIn(self.P[:12] + "…", listing)

    def test_new_reader_needs_a_grant(self):
        p = cli(self.db, "key", "reader", "nobody", ok=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("--sources", p.stderr)

    def test_revoke_ends_access_and_open_streams(self):
        k = cli(self.db, "key", "reader", "dave", "--sources", "deploys").stdout.strip()
        s = open_stream(self.c, k)
        self.assertEqual(s.status, 200)
        cli(self.db, "key", "revoke", k[:12])
        t0 = time.time()
        while s.thread.is_alive() and time.time() - t0 < 5:
            time.sleep(0.1)
        self.assertFalse(s.thread.is_alive(), "stream of a revoked key stayed open")
        r = self.c.req("GET", "/info", k)
        self.assertEqual(r.status, 401)
        self.assertEqual(r.json["error"]["code"], "unauthorized")

    def test_rotate_keeps_reader_identity_and_dismiss_state(self):
        old = cli(self.db, "key", "reader", "erin", "--sources", "deploys").stdout.strip()
        ev = self.publish(self.P, text="rotate me", display={"lifetime": "sticky"})
        r = self.c.req("POST", "/%s/dismiss" % ev["id"], old)
        self.assertEqual(r.status, 200)
        new = cli(self.db, "key", "rotate", old[:12]).stdout.strip()
        self.assertTrue(new.startswith("ahr_") and new != old)
        self.assertEqual(self.c.req("GET", "/info", old).status, 401)
        info = self.c.req("GET", "/info", new).json
        self.assertEqual(info["reader"], "erin")
        self.assertEqual(info["sources"], ["deploys"])
        evs = self.c.req("GET", "/", new, params={"type": "test.event", "limit": 500}).json["events"]
        mine = [e for e in evs if e["id"] == ev["id"]]
        self.assertTrue(mine and mine[0]["dismissed_at"], "dismiss state lost on rotation")

    def test_second_key_for_same_reader_shares_state(self):
        a = cli(self.db, "key", "reader", "frank", "--sources", "deploys").stdout.strip()
        b = cli(self.db, "key", "reader", "frank").stdout.strip()
        ev = self.publish(self.P, text="shared", display={"lifetime": "sticky"})
        s = open_stream(self.c, b)
        self.assertEqual(s.status, 200)
        time.sleep(0.3)
        self.c.req("POST", "/%s/dismiss" % ev["id"], a)
        f = s.next(lambda f: f["event"] == "state", 5)
        s.close()
        self.assertIsNotNone(f, "a dismiss through one key did not reach the same reader's other key")
        self.assertEqual(f["data"]["id"], ev["id"])

    def test_grant_change_applies_to_open_stream(self):
        k = cli(self.db, "key", "reader", "gina", "--sources", "deploys,billing").stdout.strip()
        s = open_stream(self.c, k)
        self.assertEqual(s.status, 200)
        time.sleep(0.3)
        cli(self.db, "key", "grant", "gina", "--sources", "billing")
        time.sleep(1.5)
        ev = self.publish(self.P, text="after narrowing")
        got = [f for f in s.collect(1.5) if f["event"] == "event" and f["data"]["id"] == ev["id"]]
        s.close()
        self.assertEqual(got, [], "narrowed grant still delivered a deploys event")
        self.assertEqual(self.c.req("GET", "/info", k).json["sources"], ["billing"])

    # --- sources ---------------------------------------------------------------

    def test_archive_stops_publishing(self):
        cli(self.db, "source", "add", "tmp-src", "--name", "Tmp")
        k = cli(self.db, "key", "publish", "tmp-src").stdout.strip()
        self.publish(k, text="before archive")
        cli(self.db, "source", "archive", "tmp-src")
        r = self.c.req("POST", "/", k, body={"type": "x", "text": "after"})
        self.assertEqual(r.status, 403)
        self.assertEqual(r.json["error"]["code"], "source_archived")
        slugs = [x["slug"] for x in self.c.req("GET", "/sources", self.R).json["sources"]]
        self.assertNotIn("tmp-src", slugs)

    def test_prune_respects_retention(self):
        conn = hubmod.open_db(self.db)
        now = hubmod.utcnow()
        clean = hubmod.validate_event({"type": "old.event", "text": "ancient"}, now)
        (row, _), = hubmod.publish_events(conn, "old", [clean], now)
        conn.execute("UPDATE events SET received_at = '2020-01-01T00:00:00Z' WHERE id = ?", (row["id"],))
        p = cli(self.db, "prune")
        self.assertRegex(p.stdout, r"removed [1-9]\d* events")
        self.assertIsNone(conn.execute("SELECT 1 FROM events WHERE id = ?", (row["id"],)).fetchone())
        conn.close()

    # --- fan-out -----------------------------------------------------------------

    def test_cli_send_reaches_live_streams(self):
        s = open_stream(self.c, self.R, {"source": "billing"})
        self.assertEqual(s.status, 200)
        time.sleep(0.3)
        out = cli(self.db, "send", "billing", "--text", "from the CLI", "--severity", "notice").stdout
        ev = json.loads(out)
        f = s.next(lambda f: f["event"] == "event" and f["data"]["id"] == ev["id"], 5)
        s.close()
        self.assertIsNotNone(f, "an event written by another process never reached the stream")

    def test_gap_frame_and_replay_cap(self):
        cli(self.db, "source", "add", "bulk", "--name", "Bulk")
        k = cli(self.db, "key", "reader", "henry", "--sources", "bulk").stdout.strip()
        conn = hubmod.open_db(self.db)
        start = conn.execute("SELECT COALESCE(MAX(seq), 0) FROM events").fetchone()[0]
        now = hubmod.utcnow()
        cleans = [hubmod.validate_event({"type": "bulk.x", "text": "n%d" % i}, now) for i in range(1234)]
        hubmod.publish_events(conn, "bulk", cleans, now)
        conn.close()
        s = open_stream(self.c, k, last_event_id=str(start))
        self.assertEqual(s.status, 200)
        first = s.next(lambda f: f["event"] in ("gap", "event"), 5)
        self.assertEqual(first["event"], "gap")
        self.assertEqual(first["data"], {"missed": 234})
        evs = [f for f in s.collect(3) if f["event"] == "event"]
        s.close()
        self.assertEqual(len(evs), 1000)
        self.assertEqual(evs[0]["data"]["text"], "n234")
        self.assertEqual(evs[-1]["data"]["text"], "n1233")

    def test_keepalive_comment(self):
        s = open_stream(self.c, self.R)
        self.assertEqual(s.status, 200)
        f = s.next(lambda f: f["event"] == ":comment" and f["raw"] == "keepalive", 3)
        s.close()
        self.assertIsNotNone(f)

    def test_rate_limit_has_retry_after(self):
        k = cli(self.db, "key", "publish", "billing", "--label", "burst").stdout.strip()
        statuses = []
        for i in range(40):
            r = self.c.req("POST", "/", k, body={"type": "rate.x", "text": "r", "idempotency_key": "same"})
            statuses.append(r.status)
            if r.status == 429:
                self.assertEqual(r.json["error"]["code"], "rate_limited")
                self.assertGreaterEqual(int(r.header("Retry-After")), 1)
                break
        self.assertEqual(statuses.count(429), 1)
        self.assertIn(len(statuses), (31, 32, 33), "burst should be 30 (plus refill while sending)")

    # --- HTTP details ----------------------------------------------------------------

    def test_keep_alive_survives_errors_with_bodies(self):
        conn = self.c.connect()
        body = json.dumps({"type": "x", "text": "y"}).encode()
        for path in (self.c.path + "/nope", self.c.path + "/info", self.c.path + "/"):
            conn.request("POST", path, body=body, headers={"Authorization": "Bearer " + self.R,
                                                           "Content-Type": "application/json"})
            r = conn.getresponse()
            r.read()
            self.assertIn(r.status, (403, 404, 405))
        conn.request("GET", self.c.path + "/info", headers={"Authorization": "Bearer " + self.R})
        r = conn.getresponse()
        self.assertEqual(r.status, 200)
        r.read()
        conn.close()

    def test_docs_use_public_url_and_base_path(self):
        h = HubProcess(self.db, "--public-url", "https://hub.example.com/", "--base-path", "/ambient")
        try:
            r = h.client.req("GET", "/docs")
            self.assertEqual(r.status, 200)
            self.assertIn("https://hub.example.com/ambient", r.body.decode())
            self.assertEqual(h.client.req("GET", "/info", self.R).json["docs"], "https://hub.example.com/ambient/docs")
            r = conf.Client(h.base.replace("/ambient", "/v1/events")).req("GET", "/docs")
            self.assertEqual(r.status, 404)
            r = conf.Client(h.base.replace("/ambient", "/ambientx")).req("GET", "/docs")
            self.assertEqual(r.status, 404)
        finally:
            h.stop()

    def test_error_messages_say_what_to_fix(self):
        r = self.c.req("POST", "/", self.P, body={"type": "x", "text": "t" * 301})
        self.assertEqual(r.json["error"]["message"], "text: 301 characters; the limit is 300 (put the rest in detail)")
        r = self.c.req("POST", "/", self.P, body={"type": "x", "text": "t", "display": {"effect": "spin"}})
        self.assertIn("display.effect: must be one of none | blink", r.json["error"]["message"])
        r = self.c.req("POST", "/batch", self.P, body={"events": [{"type": "x", "text": "ok"}, {"type": "x"}]})
        self.assertTrue(r.json["error"]["message"].startswith("events[1].text"), r.json)


KEY_SECRET = 12  # characters after the shown prefix must never be stored


if __name__ == "__main__":
    unittest.main()
