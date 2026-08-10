#!/usr/bin/env bash
# End-to-end tests for the Postman collection against the mock Cloudflare API,
# executed with newman (Postman's CLI runner). Each mode folder is run in isolation
# with `newman run --folder`, mirroring how an operator uses the collection.
# Requires: node, jq, and newman (npm install -g newman). Run:  ./test/run_postman_tests.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$HERE"

COLLECTION="$ROOT/postman/CloudflareAccessLicenseManager.postman_collection.json"
TMP="$(mktemp -t cf-alm-collection.XXXXXX.json)"
PASS=0; FAIL=0
trap 'rm -f "$TMP"' EXIT

for bin in node jq newman; do
  command -v "$bin" >/dev/null 2>&1 || { echo "MISSING dependency: $bin"; exit 2; }
done

# Base overrides: point at the mock, enable the removal guard.
build_collection() { # $1 = userList value
  jq --arg ul "$1" '
    (.variable[] | select(.key=="baseUrl").value)        = "http://127.0.0.1:8787" |
    (.variable[] | select(.key=="accountId").value)      = "acct-test" |
    (.variable[] | select(.key=="apiToken").value)       = "test-token" |
    (.variable[] | select(.key=="confirmRemoval").value) = "true" |
    (.variable[] | select(.key=="userList").value)       = $ul' "$COLLECTION" > "$TMP"
}

reset_mock() { node -e 'const q=require("http").request({host:"127.0.0.1",port:8787,path:"/__reset",method:"POST"},r=>{r.resume();r.on("end",()=>process.exit(0));});q.on("error",()=>process.exit(0));q.end();' 2>/dev/null; rm -f patched.json; }

# seats from the most recent removal (last PATCH batch recorded by the mock)
last_batch_seats() { node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync("patched.json","utf8"));const last=a[a.length-1]||[];console.log(last.map(x=>x.seat_uid).sort().join(","));' 2>/dev/null; }
all_false() { node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync("patched.json","utf8"));const flat=[].concat(...a);console.log(flat.length>0&&flat.every(x=>x.access_seat===false&&x.gateway_seat===false));' 2>/dev/null; }

rm -f patched.json
PORT=8787 node mock_cf.js & MOCK=$!
sleep 1

run_folder() { # $1 = folder name
  newman run "$TMP" --folder "$1" --reporters cli --reporter-cli-no-banner
}

# ---------------------------------------------------------------------------
# Inactivity Mode: default inactiveDays=90, seatType=Either -> seat-a,c,e,g
# ---------------------------------------------------------------------------
echo "=== Inactivity Mode ==="
build_collection ""
reset_mock
if run_folder "Inactivity Mode"; then echo "PASS: newman Inactivity assertions passed"; PASS=$((PASS+1)); else echo "FAIL: newman Inactivity reported failures"; FAIL=$((FAIL+1)); fi
GOT=$(last_batch_seats)
if [ "$GOT" == "seat-a,seat-c,seat-e,seat-g" ]; then echo "PASS: inactivity removed seat-a,seat-c,seat-e,seat-g"; PASS=$((PASS+1)); else echo "FAIL: inactivity removal -> got [$GOT]"; FAIL=$((FAIL+1)); fi
if [ "$(all_false)" == "true" ]; then echo "PASS: inactivity set both flags false"; PASS=$((PASS+1)); else echo "FAIL: inactivity flags not both false"; FAIL=$((FAIL+1)); fi

# ---------------------------------------------------------------------------
# User-List Mode: userList=b@ex.com,e@ex.com -> seat-b,seat-e (ignores activity)
# ---------------------------------------------------------------------------
echo "=== User-List Mode ==="
build_collection "b@ex.com, e@ex.com"
reset_mock
if run_folder "User-List Mode"; then echo "PASS: newman User-List assertions passed"; PASS=$((PASS+1)); else echo "FAIL: newman User-List reported failures"; FAIL=$((FAIL+1)); fi
GOT=$(last_batch_seats)
if [ "$GOT" == "seat-b,seat-e" ]; then echo "PASS: user-list removed seat-b,seat-e"; PASS=$((PASS+1)); else echo "FAIL: user-list removal -> got [$GOT]"; FAIL=$((FAIL+1)); fi
if [ "$(all_false)" == "true" ]; then echo "PASS: user-list set both flags false"; PASS=$((PASS+1)); else echo "FAIL: user-list flags not both false"; FAIL=$((FAIL+1)); fi

# ---------------------------------------------------------------------------
# User-List Mode by id + seat_uid, and unmatched entries skipped:
# u-a (id) + seat-g (seat_uid) + nobody@ (unknown) + f@ex.com (no seat) -> seat-a,seat-g
# ---------------------------------------------------------------------------
echo "=== User-List Mode (id/seat_uid + unmatched) ==="
build_collection "u-a, seat-g, nobody@ex.com, f@ex.com"
reset_mock
run_folder "User-List Mode" >/dev/null 2>&1
GOT=$(last_batch_seats)
if [ "$GOT" == "seat-a,seat-g" ]; then echo "PASS: user-list id/seat_uid resolve + skip unmatched"; PASS=$((PASS+1)); else echo "FAIL: user-list id/seat_uid -> got [$GOT]"; FAIL=$((FAIL+1)); fi

kill $MOCK 2>/dev/null
rm -f patched.json
echo "----"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
