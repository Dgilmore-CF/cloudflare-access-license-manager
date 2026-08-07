#!/usr/bin/env bash
# End-to-end tests for Remove-InactiveAccessSeats.ps1 against a mock Cloudflare API.
# Requires: pwsh (PowerShell 7+) and node. Run from anywhere:  ./test/run_tests.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$HERE"

BASE="http://127.0.0.1:8787"
SCRIPT="$ROOT/scripts/Remove-InactiveAccessSeats.ps1"
COMMON=(-AccountId acct123 -ApiToken testtoken -BaseUrl "$BASE")
PASS=0; FAIL=0

rm -f patched.json out.json
PORT=8787 node mock_cf.js & MOCK=$!
sleep 1

# helper: sorted seat_uids from a JSON report file (handles array or single object)
seats() { node -e 'const fs=require("fs");let a=[];try{a=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));}catch(e){}const arr=Array.isArray(a)?a:(a?[a]:[]);console.log(arr.map(x=>x.seat_uid).sort().join(","));' "$1"; }

check() { if [ "$2" == "$3" ]; then echo "PASS: $1 ($3)"; PASS=$((PASS+1)); else echo "FAIL: $1 -> expected [$2] got [$3]"; FAIL=$((FAIL+1)); fi; }

pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 90 -SeatType Either -OutputPath out.json >/dev/null 2>&1
check "Either/90 dry" "seat-a,seat-c,seat-e,seat-g" "$(seats out.json)"

pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 90 -SeatType Either -ExcludeNeverLoggedIn -OutputPath out.json >/dev/null 2>&1
check "Either/90 excludeNever" "seat-a,seat-e,seat-g" "$(seats out.json)"

pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 90 -SeatType Access -OutputPath out.json >/dev/null 2>&1
check "Access/90" "seat-a,seat-e,seat-g" "$(seats out.json)"

pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 90 -SeatType Gateway -OutputPath out.json >/dev/null 2>&1
check "Gateway/90" "seat-c,seat-e" "$(seats out.json)"

pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 90 -SeatType Both -OutputPath out.json >/dev/null 2>&1
check "Both/90" "seat-e" "$(seats out.json)"

pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 3650 -SeatType Either -OutputPath out.json >/dev/null 2>&1
check "Either/3650 none" "" "$(seats out.json)"

# Remove path (note: '-Confirm:$false' single-quoted so bash passes it literally to pwsh)
rm -f patched.json
OUT=$(pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 90 -SeatType Either -Remove '-Confirm:$false' 2>&1)
echo "$OUT" | grep -q "Removed: 4" && { echo "PASS: remove reports 4"; PASS=$((PASS+1)); } || { echo "FAIL: remove summary -> $(echo "$OUT" | tail -1)"; FAIL=$((FAIL+1)); }
PSEATS=$(node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync("patched.json","utf8"));const flat=[].concat(...a);console.log(flat.map(x=>x.seat_uid).sort().join(","));' 2>/dev/null)
check "remove PATCH seats" "seat-a,seat-c,seat-e,seat-g" "$PSEATS"
ALLFALSE=$(node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync("patched.json","utf8"));const flat=[].concat(...a);console.log(flat.every(x=>x.access_seat===false&&x.gateway_seat===false));' 2>/dev/null)
check "remove sets both false" "true" "$ALLFALSE"

# WhatIf must NOT call PATCH
rm -f patched.json
pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 90 -SeatType Either -Remove -WhatIf >/dev/null 2>&1
if [ -f patched.json ]; then echo "FAIL: WhatIf issued a PATCH"; FAIL=$((FAIL+1)); else echo "PASS: WhatIf issued no PATCH"; PASS=$((PASS+1)); fi

kill $MOCK 2>/dev/null
rm -f patched.json out.json
echo "----"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
