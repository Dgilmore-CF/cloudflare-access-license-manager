#!/usr/bin/env bash
# End-to-end test for the Postman collection against the mock Cloudflare API,
# executed with newman (Postman's CLI runner).
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

# Point the collection variables at the mock and enable the removal guard.
jq '(.variable[] | select(.key=="baseUrl").value)      = "http://127.0.0.1:8787" |
    (.variable[] | select(.key=="accountId").value)    = "acct-test" |
    (.variable[] | select(.key=="apiToken").value)     = "test-token" |
    (.variable[] | select(.key=="confirmRemoval").value) = "true" |
    (.variable[] | select(.key=="seatUid").value)      = "seat-b"' "$COLLECTION" > "$TMP"

rm -f patched.json
PORT=8787 node mock_cf.js & MOCK=$!
sleep 1

echo "=== newman run ==="
if newman run "$TMP" --reporters cli --reporter-cli-no-banner; then
  echo "PASS: newman assertions all passed"; PASS=$((PASS+1))
else
  echo "FAIL: newman reported failures"; FAIL=$((FAIL+1))
fi

# Assert the bulk removal request (first PATCH) targeted exactly the inactive seats.
BULK=$(node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync("patched.json","utf8"));console.log((a[0]||[]).map(x=>x.seat_uid).sort().join(","));' 2>/dev/null)
if [ "$BULK" == "seat-a,seat-c,seat-e,seat-g" ]; then echo "PASS: collection removed seat-a,seat-c,seat-e,seat-g"; PASS=$((PASS+1)); else echo "FAIL: bulk removal -> got [$BULK]"; FAIL=$((FAIL+1)); fi
ALLFALSE=$(node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync("patched.json","utf8"));const flat=[].concat(...a);console.log(flat.length>0&&flat.every(x=>x.access_seat===false&&x.gateway_seat===false));' 2>/dev/null)
if [ "$ALLFALSE" == "true" ]; then echo "PASS: every removal set both flags false"; PASS=$((PASS+1)); else echo "FAIL: not all removals set both flags false"; FAIL=$((FAIL+1)); fi

kill $MOCK 2>/dev/null
rm -f patched.json
echo "----"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
