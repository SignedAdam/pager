#!/bin/bash
# End-to-end check of `pager ambient` against tools/mock-hub.py.
#
# Runs the real daemon with an isolated state directory, so your own history
# and settings are never touched. The overlay does draw a few short-lived test
# lines (3 s lifetime) while it runs. Everything it starts is stopped on exit.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAGER="${PAGER_BIN:-$REPO/bin/pager}"
PORT="${PORT:-$((20000 + RANDOM % 20000))}"
BASE="http://127.0.0.1:$PORT/v1/events"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ambient-e2e.XXXXXX")"
export PAGER_AMBIENT_DIR="$WORK/state"
mkdir -p "$PAGER_AMBIENT_DIR"
DB="$WORK/hub.json"
HUBLOG="$WORK/hub.log"
LOG="$PAGER_AMBIENT_DIR/ambient.log"
PASS=0; FAIL=0
HUB_PID=""; AMB_PID=""

cleanup() {
  [ -n "$AMB_PID" ] && kill "$AMB_PID" 2>/dev/null
  [ -n "$HUB_PID" ] && kill "$HUB_PID" 2>/dev/null
  wait 2>/dev/null
  if [ "${KEEP:-0}" = 1 ]; then echo "  kept $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf '  \033[38;5;190mok\033[0m    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }
# wait_for <seconds> <shell condition>
wait_for() { local end=$((SECONDS + $1)); while [ $SECONDS -lt $end ]; do eval "$2" && return 0; sleep 0.2; done; eval "$2"; }

start_hub() {
  python3 "$REPO/tools/mock-hub.py" --port "$PORT" --db "$DB" --keepalive "${KEEPALIVE:-2}" \
    --publish "pub-test:levi-test:Levi test:#c7ff00" --publish "pub-deploys:deploys:Deploys" \
    --reader "read-test:tester:*" --reader "read-narrow:narrow:deploys" "$@" >>"$HUBLOG" 2>&1 &
  HUB_PID=$!
  wait_for 5 "curl -s -o /dev/null http://127.0.0.1:$PORT/v1/events/docs"
}
stop_hub() { kill "$HUB_PID" 2>/dev/null; wait "$HUB_PID" 2>/dev/null; HUB_PID=""; }

start_ambient() {
  PAGER_AMBIENT_URL="$BASE" PAGER_AMBIENT_KEY="read-test" PAGER_AMBIENT_WATCHDOG="${WATCHDOG:-60}" \
    "$PAGER" ambient >>"$WORK/ambient.out" 2>&1 &
  AMB_PID=$!
  wait_for 8 "\"$PAGER\" ambient --status 2>/dev/null | grep -q 'running (pid'"
}
stop_ambient() { "$PAGER" ambient --quit >/dev/null 2>&1; wait "$AMB_PID" 2>/dev/null; AMB_PID=""; }

publish() {  # publish <json> [key]
  curl -s -X POST "$BASE" -H "Authorization: Bearer ${2:-pub-test}" -H 'Content-Type: application/json' -d "$1"
}
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
status_json() { python3 - "$@" <<'PY'
import json, socket, sys, os
s = socket.socket(socket.AF_UNIX); s.settimeout(3)
s.connect(os.environ["PAGER_AMBIENT_DIR"] + "/ambient.sock")
s.sendall(b'{"op":"status"}\n'); s.shutdown(socket.SHUT_WR)
data = b""
while True:
    chunk = s.recv(65536)
    if not chunk: break
    data += chunk
print(data.decode())
PY
}
dismiss_key() { python3 - "$1" <<'PY'
import json, socket, sys, os
s = socket.socket(socket.AF_UNIX); s.connect(os.environ["PAGER_AMBIENT_DIR"] + "/ambient.sock")
s.sendall(json.dumps({"op": "dismiss", "key": sys.argv[1]}).encode() + b"\n"); s.shutdown(socket.SHUT_WR); s.recv(999)
PY
}
visible() { status_json | json "' '.join(d['visible_ids'])"; }
cursor() { status_json | json "d['connections'][0]['cursor']"; }
saved_cursor() { json "d['cursors'].get('default','')" < "$PAGER_AMBIENT_DIR/ambient-state.json" 2>/dev/null; }
settings() { cat > "$PAGER_AMBIENT_DIR/ambient.json" <<JSON
{"lifetime": 3, "max_lines": 6}
JSON
}

printf '\n  ambient e2e  %s\n  state %s\n\n' "$BASE" "$PAGER_AMBIENT_DIR"
settings

# ---------------------------------------------------------------- the basics
check "selftest passes" "\"$PAGER\" ambient --selftest >/dev/null"
start_hub
check "hub /info with reader key" "curl -s -H 'Authorization: Bearer read-test' $BASE/info | grep -q '\"key\": \"reader\"'"
check "publish key on a reader route is 403" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer pub-test' $BASE)\" = 403 ]"
check "source in body is 400" "publish '{\"type\":\"x\",\"text\":\"t\",\"source\":\"other\"}' | grep -q source_from_key"

# --------------------------------------------------------------- local mode
out=$("$PAGER" event --source test --text "**offline** line" --lifetime sticky 2>&1)
check "pager event with nothing running saves to history" "grep -q 'saved to history only' <<<\"\$out\" && grep -q 'offline' \"$PAGER_AMBIENT_DIR/events.jsonl\""

start_ambient
check "daemon starts" "[ -n \"$AMB_PID\" ] && kill -0 $AMB_PID"
check "connects to the hub" "wait_for 8 \"grep -q 'hub default: connected' '$LOG'\"" "$(tail -3 "$LOG" 2>/dev/null)"
check "local sticky written while it was down is on screen" "wait_for 3 \"visible | grep -q local/\""
second=$("$PAGER" ambient 2>&1); code=$?
check "second instance exits 0 saying it runs" "[ $code = 0 ] && grep -q 'already running' <<<\"\$second\""

id=$("$PAGER" event --source test --text "**hi** from \`pager event\`" --lifetime 3)
check "local event reaches the daemon" "wait_for 3 \"visible | grep -q 'local/$id'\""
check "local event in history" "grep -q '$id' '$PAGER_AMBIENT_DIR/events.jsonl'"
out=$("$PAGER" event --text x --effect sparkle 2>&1); code=$?
check "bad event is refused with a message" "[ $code = 2 ] && grep -q 'effect is one of' <<<\"\$out\"" "$out"

# --------------------------------------------------------------- hub events
e1=$(publish '{"type":"deploy","text":"**api** deployed","display":{"lifetime":3}}')
c1=$(json "d['cursor']" <<<"$e1"); i1=$(json "d['id']" <<<"$e1")
check "hub event arrives" "wait_for 3 \"grep -q 'event default/$i1' '$LOG'\""
check "status cursor follows" "wait_for 3 '[ \"\$(cursor)\" = \"$c1\" ]'" "cursor=$(cursor)"
check "cursor persisted to ambient-state.json" "wait_for 3 '[ \"\$(saved_cursor)\" = \"$c1\" ]'" "$(cat "$PAGER_AMBIENT_DIR/ambient-state.json" 2>/dev/null)"

out=$("$PAGER" event --hub "$BASE" --key pub-test --text "via **pager event --hub**" --type note --lifetime 3)
check "pager event --hub publishes" "grep -q '^evt_' <<<\"\$out\" && wait_for 3 \"grep -q 'event default/$out' '$LOG'\"" "$out"
out=$("$PAGER" event --hub "$BASE" --key read-test --text "x" 2>&1); code=$?
check "pager event --hub with a reader key fails clearly" "[ $code != 0 ] && grep -q wrong_key_kind <<<\"\$out\"" "$out"

# ------------------------------------------------------------------ dismiss
s1=$(publish '{"type":"down","severity":"error","text":"site **down**","display":{"lifetime":"sticky"}}')
si=$(json "d['id']" <<<"$s1")
check "sticky shows" "wait_for 3 \"visible | grep -q 'default/$si'\""
dismiss_key "default/$si"
check "dismiss from the overlay reaches the hub" "wait_for 3 \"grep -q 'dismiss $si by tester' '$HUBLOG'\""
check "hub no longer lists it as open" "! curl -s -H 'Authorization: Bearer read-test' '$BASE?sticky=open' | grep -q $si"
check "line gone" "! visible | grep -q $si"

s2=$(publish '{"type":"down","text":"other **sticky**","display":{"lifetime":"sticky"}}')
s2i=$(json "d['id']" <<<"$s2")
wait_for 3 "visible | grep -q $s2i"
curl -s -X POST -H 'Authorization: Bearer read-test' "$BASE/$s2i/dismiss" >/dev/null
check "state frame from another client removes it" "wait_for 3 '! visible | grep -q $s2i'"
check "logged as from the hub" "grep -q 'dismissed default/$s2i (from hub)' '$LOG'"
curl -s -X DELETE -H 'Authorization: Bearer read-test' "$BASE/$s2i/dismiss" >/dev/null
check "dismissed_at null restores it" "wait_for 3 'visible | grep -q $s2i'"
curl -s -X POST -H 'Authorization: Bearer read-narrow' "$BASE/$s2i/dismiss" -o /dev/null
check "another reader's dismiss does not touch ours (and is 404 outside its grant)" "sleep 0.5; visible | grep -q $s2i"

# ------------------------------------------------------------------- resume
s3=$(publish '{"type":"down","text":"dismissed **offline**","display":{"lifetime":"sticky"}}' | json "d['id']")
wait_for 3 "visible | grep -q $s3"
before=$(cursor)
stop_hub
check "notices the hub is gone" "wait_for 5 \"grep -q 'hub default: stream ended\\|hub default: network' '$LOG'\""
dismiss_key "default/$s3"
check "dismiss while offline is noted" "wait_for 3 \"grep -q 'dismiss $s3 -> offline' '$LOG'\""
start_hub
check "and reaches the hub after reconnecting" "wait_for 15 \"grep -q 'dismiss $s3 by tester' '$HUBLOG'\""
r1=$(publish '{"type":"push","text":"pushed while **away** 1","display":{"lifetime":3}}')
r2=$(publish '{"type":"push","text":"pushed while **away** 2","display":{"lifetime":3}}')
rc=$(json "d['cursor']" <<<"$r2")
check "reconnects with Last-Event-ID" "wait_for 15 \"grep -q 'last-event-id=$before replay=' '$HUBLOG'\"" "$(grep 'stream open' "$HUBLOG" | tail -2)"
check "both missed events caught up" "wait_for 3 '[ \"\$(cursor)\" = \"$rc\" ]'"

# ----------------------------------------------------------------- restart
stop_ambient
check "quit leaves no process" "! kill -0 ${AMB_PID:-999999} 2>/dev/null && [ ! -S '$PAGER_AMBIENT_DIR/ambient.sock' ]"
off=$(publish '{"type":"push","text":"while pager was off","display":{"lifetime":3}}' | json "d['cursor']")
start_ambient
check "after a restart the sticky is restored from sticky=open" "wait_for 5 'visible | grep -q $s2i'"
check "and the dismissed one stays gone" "! visible | grep -q $si"
check "resumes from the persisted cursor" "wait_for 5 \"grep -q 'last-event-id=$rc replay=1' '$HUBLOG'\""
"$PAGER" ambient --status | sed 's/^/      /'
stop_ambient
check "restoring an old sticky never winds the saved cursor back" "[ \"\$(saved_cursor)\" = \"$off\" ]" "saved $(saved_cursor), want $off"

# ---------------------------------------------------------------------- gap
for n in 1 2 3; do publish "{\"type\":\"push\",\"text\":\"gap $n\",\"display\":{\"lifetime\":3}}" >/dev/null; done
stop_hub; start_hub --replay-max 1
start_ambient
check "a gap frame is logged" "wait_for 6 \"grep -q 'gap, 2 event' '$LOG'\""
stop_ambient

# ----------------------------------------------------------------- watchdog
stop_hub; KEEPALIVE=1 start_hub --silent
WATCHDOG=3 start_ambient
check "silent stream trips the watchdog" "wait_for 15 \"grep -q 'no bytes for' '$LOG'\""
stop_ambient

# -------------------------------------------------------------- connections
stop_hub; start_hub
NAME="e2e-$$"
out=$(PAGER_AMBIENT_URL= PAGER_AMBIENT_KEY= "$PAGER" ambient connect "$BASE" --key pub-test --name "$NAME" 2>&1)
check "connect refuses a publish key" "grep -q 'needs a reader key' <<<\"\$out\"" "$out"
out=$(PAGER_AMBIENT_URL= PAGER_AMBIENT_KEY= "$PAGER" ambient connect "$BASE" --key read-narrow --name "$NAME" 2>&1)
check "connect validates via /info and shows grants" "grep -q 'connected to Mock hub as narrow. Sources: deploys' <<<\"\$out\"" "$out"
check "connections lists it" "PAGER_AMBIENT_URL= PAGER_AMBIENT_KEY= \"$PAGER\" ambient connections | grep -q '$NAME'"
env -u PAGER_AMBIENT_URL -u PAGER_AMBIENT_KEY "$PAGER" ambient >>"$WORK/ambient.out" 2>&1 &
AMB_PID=$!
check "daemon reads the key from the Keychain" "wait_for 8 \"grep -q 'hub $NAME: starting.*key from Keychain' '$LOG'\"" "$(tail -3 "$LOG")"
check "and connects" "wait_for 8 \"grep -q 'hub $NAME: connected' '$LOG'\""
d1=$(publish '{"type":"deploy","text":"only **deploys** reach a narrow key","display":{"lifetime":3}}' pub-deploys | json "d['id']")
l1=$(publish '{"type":"note","text":"levi-test is not granted"}' | json "d['id']")
check "granted source arrives" "wait_for 3 \"grep -q 'event $NAME/$d1' '$LOG'\""
check "ungranted source does not" "sleep 0.5; ! grep -q '$l1' '$LOG'"
stop_ambient
check "disconnect removes it" "PAGER_AMBIENT_URL= \"$PAGER\" ambient disconnect '$NAME' | grep -q removed && ! grep -q '$NAME' '$PAGER_AMBIENT_DIR/ambient.json'"

# ------------------------------------------------------------------ status
"$PAGER" ambient --status | sed 's/^/      /'
stop_hub

printf '\n  %s passed, %s failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
