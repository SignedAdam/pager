# ambient-hub

A hub collects small events from your programs and streams them to the people who should see them. Pager Ambient shows them as one quiet line on your Mac. Any server that speaks the [Ambient protocol](../docs/protocol.md) is a hub; this directory is the reference one, so anybody can run their own.

It is one Python file with no dependencies beyond the standard library (Python 3.9 or newer) and keeps everything in one SQLite file. A Dockerfile is included. A team of hundreds is fine on one small VM.

Setting up a hub takes about five minutes:

1. run the server;
2. add a **source** for each thing that publishes (`deploys`, `billing`, `backups`);
3. give each publisher a **publish key** for its source;
4. give each person a **reader key** granted the sources they may see.

Publish keys (`ahp_…`) can only post events to their one source. Reader keys (`ahr_…`) can only read, and only what they were granted. Keys are printed once and stored as SHA-256 hashes.

## Try it locally

```sh
cd hub
python3 ambient-hub.py source add deploys --name Deploys --color "#c7ff00"
python3 ambient-hub.py key publish deploys --label ci        # prints ahp_…
python3 ambient-hub.py key reader me --all                   # prints ahr_…
python3 ambient-hub.py serve
```

The database is `./hub.db` unless you pass `--db` or set `AMBIENT_HUB_DB`. In another terminal:

```sh
curl -N -H "Authorization: Bearer ahr_…" http://127.0.0.1:8790/v1/events/stream
```

and in a third:

```sh
curl -H "Authorization: Bearer ahp_…" \
  -d '{"type":"deploy.failed","severity":"error","text":"**api** failed on `main`"}' \
  http://127.0.0.1:8790/v1/events
```

The event appears on the stream. Connect Pager with `pager ambient connect http://127.0.0.1:8790/v1/events --key ahr_…`.

Every hub serves its publisher's guide at `<base URL>/docs`, with this hub's real URL in every example (curl, shell, JavaScript, Python, Go, Swift). Give a publisher the base URL and a publish key, and point them, or their coding agent, at that page.

## A person on a VPS

You need a Linux server with a domain name pointing at it. With Docker:

```sh
git clone https://github.com/SignedAdam/pager.git && cd pager
docker build -t ambient-hub hub/
docker run -d --name ambient-hub --restart unless-stopped \
  -p 127.0.0.1:8790:8790 -v ambient-hub:/data \
  -e AMBIENT_HUB_PUBLIC_URL=https://hub.example.com \
  -e AMBIENT_HUB_NAME="Adam's hub" \
  ambient-hub

alias hub='docker exec -i ambient-hub python3 /app/ambient-hub.py'
hub source add deploys --name Deploys --color "#c7ff00"
hub source add backups --name Backups
hub key publish deploys --label github-actions
hub key publish backups --label nas
hub key reader adam-mac --all
```

Then put [Caddy](#behind-a-reverse-proxy) in front of it for HTTPS. Your base URL is `https://hub.example.com/v1/events`.

Without Docker, copy the one file and run it under systemd:

```sh
sudo useradd --system --home /var/lib/ambient-hub --create-home ambient
sudo install -D -m 644 hub/ambient-hub.py /opt/ambient-hub/ambient-hub.py
sudo tee /etc/systemd/system/ambient-hub.service >/dev/null <<'EOF'
[Unit]
Description=Ambient hub
After=network.target

[Service]
User=ambient
Environment=AMBIENT_HUB_DB=/var/lib/ambient-hub/hub.db
Environment=AMBIENT_HUB_LISTEN=127.0.0.1:8790
Environment=AMBIENT_HUB_PUBLIC_URL=https://hub.example.com
Environment="AMBIENT_HUB_NAME=Adam's hub"
ExecStart=/usr/bin/python3 /opt/ambient-hub/ambient-hub.py serve
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now ambient-hub

alias hub='sudo -u ambient env AMBIENT_HUB_DB=/var/lib/ambient-hub/hub.db python3 /opt/ambient-hub/ambient-hub.py'
hub source list
```

Run admin commands as the same user as the server, so SQLite's `-wal` and `-shm` files keep the right owner.

## A company

One hub serves the whole company. The admin decides who sees what, and the hub enforces it on every request and every stream frame. People can narrow what they see in Pager; they can never widen it.

Make one source per system or team:

```sh
hub source add deploys  --name Deploys  --color "#c7ff00"
hub source add incidents --name Incidents --color "#ff5f57"
hub source add sales    --name Sales    --retention-days 365
hub source add payroll  --name Payroll  --retention-days 30
```

Give each system its own publish key. A leaked key can only add events to its own source, and you can revoke it without touching the others:

```sh
hub key publish deploys   --label github-actions
hub key publish incidents --label pagerduty-webhook
hub key publish sales     --label crm
```

Give each employee a reader key, granted only the sources they may see:

```sh
hub key reader alice --sources deploys,incidents          # engineer
hub key reader bob   --sources sales                      # sales
hub key reader ceo   --all                                # everything, including future sources
```

That is how the person running the hub controls visibility. Alice never receives a `sales` or `payroll` event: not in history, not on her stream, not in `/sources`. Asking for one explicitly gets 403.

Change a grant at any time. Open streams pick it up within a second:

```sh
hub key grant alice --sources deploys,incidents,sales
```

When someone leaves, revoke their key. Every request with it gets 401 from then on, and their open streams close within a second. Nothing new reaches them; only what they had already received stays in their local history:

```sh
hub key list                       # find the key by its first 12 characters
hub key revoke ahr_3kF9x2ab
```

To replace a key that may have leaked, rotate it. The new key belongs to the same reader, so the person's dismissed events and grant carry over:

```sh
hub key rotate ahr_3kF9x2ab        # prints the new key, revokes the old one
```

Dismissals are per reader. When Alice dismisses a sticky incident on her Mac it disappears on her other devices, and stays open for everyone else. A person with several devices can use one reader for all of them (`hub key reader alice` again issues another key for the same reader) or one reader per device.

## Behind a reverse proxy

The stream is Server-Sent Events: a long-lived response that must not be buffered. The hub sends `X-Accel-Buffering: no` and a keepalive comment every 15 seconds, but set the proxy up explicitly anyway.

Caddy (gets and renews the HTTPS certificate by itself):

```caddy
hub.example.com {
	reverse_proxy 127.0.0.1:8790 {
		flush_interval -1
	}
}
```

nginx:

```nginx
location /v1/events {
    proxy_pass http://127.0.0.1:8790;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_buffering off;              # stream events as they happen
    proxy_cache off;
    proxy_read_timeout 1h;            # keepalives arrive every 15 s; anything over 20 s works
    client_max_body_size 64k;         # the hub itself answers 413 above 16 KB, in the protocol's shape
}
```

Set `--public-url` (or `AMBIENT_HUB_PUBLIC_URL`) to the address people use, so `/docs` and `/info` show it. Without it the hub uses the `Host` and `X-Forwarded-Proto` headers.

To serve the hub under another path, set `--base-path` (default `/v1/events`). `GET /healthz` at the server root answers `ok` for health checks.

## Commands

| command | does |
|---|---|
| `serve` | run the hub |
| `source add <slug> --name N [--color #hex] [--retention-days 90]` | add a source; retention `0` keeps events forever |
| `source update <slug> [--name] [--color] [--retention-days] [--unarchive]` | change a source |
| `source list` | sources with event counts |
| `source archive <slug>` | stop accepting events (publishers get 403) and hide it from readers; its events stay until retention removes them |
| `key publish <source> [--label L]` | new publish key, printed once |
| `key reader <label> --sources a,b \| --all` | new reader with a key, printed once; for an existing reader, another key for the same reader |
| `key grant <reader> --sources a,b \| --all` | replace a reader's grant |
| `key list` | all keys, shown by their first 12 characters |
| `key revoke <prefix>` | revoke a key |
| `key rotate <prefix>` | new key for the same reader or source; revokes the old one |
| `send <source> --text T [--type] [--severity] [--detail] [--subject] [--url] [--sticky] [--data JSON]` | publish a test event without a key |
| `prune` | delete events past their source's retention now (the server also does this daily) |

Admin commands open the database directly and are safe while the server runs. A new key is printed alone on stdout (the explanation goes to stderr), so `KEY=$(hub key publish deploys)` works.

## Configuration

| flag | environment | default |
|---|---|---|
| `--db` | `AMBIENT_HUB_DB` | `./hub.db` |
| `--listen` | `AMBIENT_HUB_LISTEN` | `127.0.0.1:8790` (`0.0.0.0:8790` in Docker) |
| `--public-url` | `AMBIENT_HUB_PUBLIC_URL` | taken from request headers |
| `--base-path` | `AMBIENT_HUB_BASE_PATH` | `/v1/events` |
| `--name` | `AMBIENT_HUB_NAME` | `Ambient hub` |
| `--quiet` | `AMBIENT_HUB_QUIET=1` | access log on stderr |

Limits are the protocol's defaults: 16 KB bodies, 120 publishes per minute per key with bursts of 30 (a batch costs one per 10 events), 8 concurrent streams per reader key, replay of up to 1000 events on resume. Idempotency keys are remembered for 7 days.

Back up with SQLite's online backup, which is safe while the hub runs:

```sh
sqlite3 /var/lib/ambient-hub/hub.db ".backup /backups/hub-$(date +%F).db"
```

## Conformance

`conformance.py` tests any hub against the protocol from the outside: publish, idempotency, validation errors, key kinds, list ordering and paging, `sticky=open`, live streams, resume, `state` frames, per-reader dismiss state, grant filtering, `/info`, `/docs`. If you implement the protocol on your own stack, run it against your server:

```sh
python3 hub/conformance.py https://hub.example.com/v1/events \
  --publish-key ahp_…          `# any source S` \
  --reader-key ahr_…           `# a reader granted S` \
  --reader-key-2 ahr_…         `# a different reader, also granted S` \
  --restricted-reader ahr_…    `# a reader NOT granted S`
```

It publishes about 20 small `debug` events of type `conformance.<run>` with short lifetimes, and dismisses its own sticky events when it is done. Add `--check-rate-limit`, `--check-gap` (publishes about 1010 events) and `--slow` (waits for a keepalive) for the full run. It exits non-zero when something fails and says what.

The hub's own tests start a fresh hub on a random port, run the conformance suite against it, then test the parts the protocol leaves to the hub (CLI, revocation, rotation, prune):

```sh
python3 hub/test_hub.py
```

## Bridge: copy events from one hub to another (optional)

Pager connects to any number of hubs directly, so you rarely need this. If something can only hold one connection, this script reads everything one reader key can see on hub A and publishes it to hub B as B's source:

```python
#!/usr/bin/env python3
# bridge.py: copy every event one reader key can see on hub A into hub B. Optional; read the caveat first.
import json, os, time, urllib.request

FROM, FROM_KEY = os.environ["FROM_URL"], os.environ["FROM_READER_KEY"]
TO, TO_KEY = os.environ["TO_URL"], os.environ["TO_PUBLISH_KEY"]
FIELDS = ("type", "text", "severity", "detail", "subject", "url", "occurred_at", "display", "data")
last = None  # cursor of the last event seen; resume from it after a dropped connection

while True:
    try:
        headers = {"Authorization": "Bearer " + FROM_KEY, **({"Last-Event-ID": last} if last else {})}
        with urllib.request.urlopen(urllib.request.Request(FROM + "/stream", headers=headers), timeout=60) as s:
            kind = None
            for raw in s:
                line = raw.decode().rstrip("\r\n")
                if line.startswith("event: "):
                    kind = line[7:]
                elif line.startswith("data: ") and kind == "event":
                    ev = json.loads(line[6:])
                    last = ev["cursor"]
                    body = {k: ev[k] for k in FIELDS if ev.get(k) not in (None, {})}
                    body["idempotency_key"] = "bridge-" + ev["id"]  # a replay never duplicates
                    req = urllib.request.Request(TO, json.dumps(body).encode(), method="POST", headers={
                        "Authorization": "Bearer " + TO_KEY, "Content-Type": "application/json"})
                    try:
                        urllib.request.urlopen(req, timeout=3).close()
                    except Exception as e:
                        print("dropped", ev["id"], e)
    except Exception as e:
        print("reconnecting:", e)
        time.sleep(5)
```

**Caveat.** A bridge moves data out of hub A into infrastructure that A's owner does not control. Hub A's retention, audit and grants no longer apply to the copies, and revoking the reader key stops new copies but does not delete the old ones. Do not bridge a company hub into a personal one without the company's permission. Connecting Pager to both hubs directly gives the same merged view without copying anything.
