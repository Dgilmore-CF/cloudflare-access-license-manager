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

# Reset the mock's accumulated PATCH log so each removal assertion is hermetic.
reset() { node -e 'const q=require("http").request({host:"127.0.0.1",port:8787,path:"/__reset",method:"POST"},r=>{r.resume();r.on("end",()=>process.exit(0));});q.on("error",()=>process.exit(0));q.end();' 2>/dev/null; rm -f patched.json; }

# helper: "seat_uid=basis" pairs from a JSON report, sorted
bases() { node -e 'const fs=require("fs");let a=[];try{a=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));}catch(e){}const arr=Array.isArray(a)?a:(a?[a]:[]);console.log(arr.map(x=>x.seat_uid+"="+x.basis).sort().join(","));' "$1"; }
# helper: value of a field for a given seat_uid
field() { node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const r=a.find(x=>x.seat_uid===process.argv[2]);console.log(r?String(r[process.argv[3]]):"<missing>");' "$1" "$2" "$3"; }

echo "--- inactivity mode ---"
# Activity = later of Access login and WARP device last_seen_at. See mock_cf.js for the fixture table.
pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 90 -SeatType Either -OutputPath out.json >/dev/null 2>&1
check "Either/90 dry" "seat-a,seat-e,seat-g,seat-i,seat-j" "$(seats out.json)"
check "Either/90 basis per seat" "seat-a=last_successful_login,seat-e=last_successful_login,seat-g=last_successful_login,seat-i=device_last_seen,seat-j=created_at (never logged in)" "$(bases out.json)"
check "WARP-only active user (Carol) NOT flagged" "" "$(field out.json seat-c basis | grep -v '<missing>')"
check "stale Access login but recent device (Heidi) NOT flagged" "" "$(field out.json seat-h basis | grep -v '<missing>')"
check "device-only user days_inactive from device" "120" "$(field out.json seat-i days_inactive)"
check "device-only user last_device_seen populated" "true" "$( [ "$(field out.json seat-i last_device_seen)" != "null" ] && echo true || echo false )"
check "no-device user last_device_seen null" "null" "$(field out.json seat-a last_device_seen)"

pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 90 -SeatType Either -ExcludeNeverLoggedIn -OutputPath out.json >/dev/null 2>&1
check "Either/90 excludeNever" "seat-a,seat-e,seat-g,seat-i" "$(seats out.json)"

pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 90 -SeatType Access -OutputPath out.json >/dev/null 2>&1
check "Access/90" "seat-a,seat-e,seat-g,seat-j" "$(seats out.json)"

pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 90 -SeatType Gateway -OutputPath out.json >/dev/null 2>&1
check "Gateway/90" "seat-e,seat-i" "$(seats out.json)"

pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 90 -SeatType Both -OutputPath out.json >/dev/null 2>&1
check "Both/90" "seat-e" "$(seats out.json)"

# Threshold boundary: Ivan's device was seen 120d ago -> flagged at 119, not at 121.
pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 119 -SeatType Gateway -OutputPath out.json >/dev/null 2>&1
check "Gateway/119 includes 120d device user" "seat-e,seat-i" "$(seats out.json)"
pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 121 -SeatType Gateway -OutputPath out.json >/dev/null 2>&1
check "Gateway/121 excludes 120d device user" "seat-e" "$(seats out.json)"

pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 3650 -SeatType Either -OutputPath out.json >/dev/null 2>&1
check "Either/3650 none" "" "$(seats out.json)"

# -IgnoreDeviceActivity reproduces the Access-only (legacy) behaviour: WARP-only users look never-logged-in.
pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 90 -SeatType Either -IgnoreDeviceActivity -OutputPath out.json >/dev/null 2>&1
check "Either/90 IgnoreDeviceActivity (legacy)" "seat-a,seat-c,seat-e,seat-g,seat-h,seat-i,seat-j" "$(seats out.json)"

# Users endpoint without result_info.total_pages must still paginate through all users.
pwsh -NoProfile -File "$SCRIPT" -AccountId acct-nototal -ApiToken testtoken -BaseUrl "$BASE" -InactiveDays 90 -SeatType Either -OutputPath out.json >/dev/null 2>&1
check "pagination without total_pages" "seat-a,seat-e,seat-g,seat-i,seat-j" "$(seats out.json)"

# Token that cannot read device registrations must fail loudly (no silent Access-only fallback)...
rm -f out.json
OUT=$(pwsh -NoProfile -File "$SCRIPT" -AccountId acct-nodev -ApiToken testtoken -BaseUrl "$BASE" -InactiveDays 90 -OutputPath out.json 2>&1); EC=$?
if [ "$EC" -ne 0 ] && [ ! -f out.json ] && echo "$OUT" | grep -q "IgnoreDeviceActivity"; then echo "PASS: device 403 fails fast with guidance (exit $EC)"; PASS=$((PASS+1)); else echo "FAIL: device 403 should abort -> exit $EC"; FAIL=$((FAIL+1)); fi
# ...unless the operator explicitly opts out.
pwsh -NoProfile -File "$SCRIPT" -AccountId acct-nodev -ApiToken testtoken -BaseUrl "$BASE" -InactiveDays 90 -IgnoreDeviceActivity -OutputPath out.json >/dev/null 2>&1
check "device 403 + IgnoreDeviceActivity proceeds" "seat-a,seat-c,seat-e,seat-g,seat-h,seat-i,seat-j" "$(seats out.json)"

# Remove path (note: '-Confirm:$false' single-quoted so bash passes it literally to pwsh)
reset
OUT=$(pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 90 -SeatType Either -Remove '-Confirm:$false' 2>&1)
echo "$OUT" | grep -q "Removed: 5" && { echo "PASS: remove reports 5"; PASS=$((PASS+1)); } || { echo "FAIL: remove summary -> $(echo "$OUT" | tail -1)"; FAIL=$((FAIL+1)); }
PSEATS=$(node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync("patched.json","utf8"));const flat=[].concat(...a);console.log(flat.map(x=>x.seat_uid).sort().join(","));' 2>/dev/null)
check "remove PATCH seats" "seat-a,seat-e,seat-g,seat-i,seat-j" "$PSEATS"
ALLFALSE=$(node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync("patched.json","utf8"));const flat=[].concat(...a);console.log(flat.every(x=>x.access_seat===false&&x.gateway_seat===false));' 2>/dev/null)
check "remove sets both false" "true" "$ALLFALSE"

# WhatIf must NOT call PATCH
rm -f patched.json
pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 90 -SeatType Either -Remove -WhatIf >/dev/null 2>&1
if [ -f patched.json ]; then echo "FAIL: WhatIf issued a PATCH"; FAIL=$((FAIL+1)); else echo "PASS: WhatIf issued no PATCH"; PASS=$((PASS+1)); fi

# =====================================================================
# Explicit user-list mode
# =====================================================================
echo "--- user-list mode ---"

# Fixture files (cleaned up at the end).
printf '# offboarding list\nb@ex.com\ne@ex.com\n' > offboard.txt
printf 'email,name\nb@ex.com,Bob\ne@ex.com,Eve\n'   > offboard.csv
printf '["b@ex.com","e@ex.com"]\n'                   > offboard.json
printf '[{"email":"b@ex.com"},{"seat_uid":"seat-e"}]\n' > offboard-objs.json

# List mode ignores activity: Bob (active 10d ago) is still targeted when named.
pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -UserList b@ex.com,e@ex.com -OutputPath out.json >/dev/null 2>&1
check "list by email (ignores activity)" "seat-b,seat-e" "$(seats out.json)"

# Single comma-separated string (how -File passes -UserList "a,b" without auto-splitting).
pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -UserList "a@ex.com,g@ex.com" -OutputPath out.json >/dev/null 2>&1
check "list comma-string" "seat-a,seat-g" "$(seats out.json)"

# Resolve by id and by seat_uid, not just email.
pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -UserList u-a,seat-g -OutputPath out.json >/dev/null 2>&1
check "list by id + seat_uid" "seat-a,seat-g" "$(seats out.json)"

pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -UserListPath offboard.txt -OutputPath out.json >/dev/null 2>&1
check "list .txt file" "seat-b,seat-e" "$(seats out.json)"

pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -UserListPath offboard.csv -OutputPath out.json >/dev/null 2>&1
check "list .csv file" "seat-b,seat-e" "$(seats out.json)"

pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -UserListPath offboard.json -OutputPath out.json >/dev/null 2>&1
check "list .json file (strings)" "seat-b,seat-e" "$(seats out.json)"

pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -UserListPath offboard-objs.json -OutputPath out.json >/dev/null 2>&1
check "list .json file (objects)" "seat-b,seat-e" "$(seats out.json)"

# Inline list + file are merged and de-duplicated (b named in both).
pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -UserList b@ex.com -UserListPath offboard.json -OutputPath out.json >/dev/null 2>&1
check "list merge+dedup" "seat-b,seat-e" "$(seats out.json)"

# SeatType filter applies in list mode: Carol holds only a Gateway seat.
pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -UserList c@ex.com -SeatType Access -OutputPath out.json >/dev/null 2>&1
check "list SeatType Access excludes gateway-only" "" "$(seats out.json)"
pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -UserList c@ex.com -SeatType Gateway -OutputPath out.json >/dev/null 2>&1
check "list SeatType Gateway matches" "seat-c" "$(seats out.json)"

# Unmatched entries are skipped: Frank holds no seat, nobody@ is unknown.
pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -UserList f@ex.com,nobody@ex.com,e@ex.com -OutputPath out.json >/dev/null 2>&1
check "list skips unmatched" "seat-e" "$(seats out.json)"

# Remove path in list mode issues the correct PATCH.
reset
OUT=$(pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -UserList b@ex.com,e@ex.com -Remove '-Confirm:$false' 2>&1)
echo "$OUT" | grep -q "Removed: 2" && { echo "PASS: list remove reports 2"; PASS=$((PASS+1)); } || { echo "FAIL: list remove summary -> $(echo "$OUT" | tail -1)"; FAIL=$((FAIL+1)); }
LSEATS=$(node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync("patched.json","utf8"));const flat=[].concat(...a);console.log(flat.map(x=>x.seat_uid).sort().join(","));' 2>/dev/null)
check "list remove PATCH seats" "seat-b,seat-e" "$LSEATS"
LFALSE=$(node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync("patched.json","utf8"));const flat=[].concat(...a);console.log(flat.length>0&&flat.every(x=>x.access_seat===false&&x.gateway_seat===false));' 2>/dev/null)
check "list remove sets both false" "true" "$LFALSE"

# WhatIf in list mode must NOT call PATCH.
rm -f patched.json
pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -UserList b@ex.com -Remove -WhatIf >/dev/null 2>&1
if [ -f patched.json ]; then echo "FAIL: list WhatIf issued a PATCH"; FAIL=$((FAIL+1)); else echo "PASS: list WhatIf issued no PATCH"; PASS=$((PASS+1)); fi

# Empty user-list file must fail fast (no report written).
rm -f out.json
printf '# nothing but a comment\n\n' > empty.txt
pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -UserListPath empty.txt -OutputPath out.json >/dev/null 2>&1
EC=$?
if [ "$EC" -ne 0 ] && [ ! -f out.json ]; then echo "PASS: empty list errors (exit $EC, no report)"; PASS=$((PASS+1)); else echo "FAIL: empty list should error -> exit $EC, out.json exists=$([ -f out.json ] && echo yes || echo no)"; FAIL=$((FAIL+1)); fi

# Inactivity and user-list parameters are mutually exclusive (parameter sets).
pwsh -NoProfile -File "$SCRIPT" "${COMMON[@]}" -InactiveDays 90 -UserList b@ex.com >/dev/null 2>&1
EC=$?
if [ "$EC" -ne 0 ]; then echo "PASS: -InactiveDays + -UserList rejected (exit $EC)"; PASS=$((PASS+1)); else echo "FAIL: -InactiveDays + -UserList should be rejected"; FAIL=$((FAIL+1)); fi

rm -f offboard.txt offboard.csv offboard.json offboard-objs.json empty.txt

kill $MOCK 2>/dev/null
rm -f patched.json out.json
echo "----"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
