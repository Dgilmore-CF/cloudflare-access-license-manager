// Builds the Postman collection + environment for Cloudflare Access License Manager.
// Two modes, each in its own folder:
//   - Inactivity Mode: flag seats whose last login is older than a threshold.
//   - User-List Mode:  flag seats for an explicit list of users (email / id / seat_uid).
// Both modes populate the shared `flaggedSeats` variable, then a guarded Remove
// request frees those seats (access_seat=false AND gateway_seat=false).
const fs = require("fs");
const path = require("path");

// Output next to this script (the repo's postman/ folder). Run: node postman/build_postman.js
const outDir = __dirname;

// ---------------------------------------------------------------------------
// Inactivity Mode: list + flag by last-login age
// ---------------------------------------------------------------------------
const inactivityPreReq = [
  "// Initialise pagination and reset the flagged list at the start of a fresh scan.",
  "let page = pm.collectionVariables.get('_page');",
  "if (!page) {",
  "  pm.collectionVariables.set('_page', '1');",
  "  pm.collectionVariables.set('flaggedSeats', '[]');",
  "  console.log('Starting inactive-seat scan (page 1)...');",
  "}",
];

const inactivityTest = [
  "const res = pm.response.json();",
  "pm.test('List users request succeeded', function () {",
  "  pm.expect(pm.response.code).to.eql(200);",
  "  pm.expect(res.success).to.be.true;",
  "});",
  "if (!res.success) { console.error('API error:', JSON.stringify(res.errors)); return; }",
  "",
  "const inactiveDays = parseInt(pm.collectionVariables.get('inactiveDays') || '90', 10);",
  "const seatType = pm.collectionVariables.get('seatType') || 'Either';",
  "const excludeNever = String(pm.collectionVariables.get('excludeNeverLoggedIn')).toLowerCase() === 'true';",
  "const now = Date.now();",
  "const cutoff = now - inactiveDays * 24 * 60 * 60 * 1000;",
  "",
  "function holdsTarget(u) {",
  "  const a = u.access_seat === true;",
  "  const g = u.gateway_seat === true;",
  "  switch (seatType) {",
  "    case 'Access':  return a;",
  "    case 'Gateway': return g;",
  "    case 'Both':    return a && g;",
  "    default:        return a || g; // Either",
  "  }",
  "}",
  "",
  "let collected = JSON.parse(pm.collectionVariables.get('flaggedSeats') || '[]');",
  "(res.result || []).forEach(function (u) {",
  "  if (!holdsTarget(u) || !u.seat_uid) return;",
  "  let basis = 'last_successful_login';",
  "  let refStr = u.last_successful_login;",
  "  if (!refStr) {",
  "    if (excludeNever) return;",
  "    refStr = u.created_at;",
  "    basis = 'created_at (never logged in)';",
  "  }",
  "  if (!refStr) return;",
  "  const ref = Date.parse(refStr);",
  "  if (isNaN(ref)) return;",
  "  if (ref < cutoff) {",
  "    collected.push({",
  "      seat_uid: u.seat_uid,",
  "      email: u.email,",
  "      last_successful_login: u.last_successful_login || null,",
  "      days_inactive: Math.floor((now - ref) / (24 * 60 * 60 * 1000)),",
  "      basis: basis",
  "    });",
  "  }",
  "});",
  "pm.collectionVariables.set('flaggedSeats', JSON.stringify(collected));",
  "",
  "// Pagination: continue while more pages remain (Collection Runner / Newman only).",
  "const info = res.result_info || {};",
  "const page = parseInt(pm.collectionVariables.get('_page') || '1', 10);",
  "const totalPages = parseInt(info.total_pages || 1, 10);",
  "console.log('Scanned page ' + page + '/' + totalPages + ' - flagged so far: ' + collected.length);",
  "if (page < totalPages) {",
  "  pm.collectionVariables.set('_page', String(page + 1));",
  "  postman.setNextRequest(pm.info.requestName);",
  "} else {",
  "  pm.collectionVariables.unset('_page');",
  "  const body = collected.map(function (c) {",
  "    return { seat_uid: c.seat_uid, access_seat: false, gateway_seat: false };",
  "  });",
  "  pm.collectionVariables.set('removalBody', JSON.stringify(body));",
  "  console.log('SCAN COMPLETE. ' + collected.length + ' inactive seat(s) flagged.');",
  "  if (collected.length) { console.log(JSON.stringify(collected, null, 2)); }",
  "}",
];

// ---------------------------------------------------------------------------
// User-List Mode: flag seats for an explicit list of users
// ---------------------------------------------------------------------------
const listResolvePreReq = [
  "// Parse the userList on the first page, then paginate to resolve every entry.",
  "let page = pm.collectionVariables.get('_page');",
  "if (!page) {",
  "  const raw = pm.collectionVariables.get('userList') || '';",
  "  const tokens = raw.split(/[\\s,;]+/).map(function (s) { return s.trim(); })",
  "    .filter(function (s) { return s && s.indexOf('#') !== 0; });",
  "  const seen = {}; const uniq = [];",
  "  tokens.forEach(function (t) { const k = t.toLowerCase(); if (!seen[k]) { seen[k] = 1; uniq.push(t); } });",
  "  if (!uniq.length) {",
  "    throw new Error(\"userList is empty. Set the 'userList' variable to a comma / space / newline separated list of emails, user IDs, or seat UIDs.\");",
  "  }",
  "  pm.collectionVariables.set('_page', '1');",
  "  pm.collectionVariables.set('_lmPending', JSON.stringify(uniq));",
  "  pm.collectionVariables.set('_lmNoSeat', '[]');",
  "  pm.collectionVariables.set('flaggedSeats', '[]');",
  "  console.log('Resolving ' + uniq.length + ' user-list entr(ies) (page 1)...');",
  "}",
];

const listResolveTest = [
  "const res = pm.response.json();",
  "pm.test('List users request succeeded', function () {",
  "  pm.expect(pm.response.code).to.eql(200);",
  "  pm.expect(res.success).to.be.true;",
  "});",
  "if (!res.success) { console.error('API error:', JSON.stringify(res.errors)); return; }",
  "",
  "const seatType = pm.collectionVariables.get('seatType') || 'Either';",
  "function holdsTarget(u) {",
  "  const a = u.access_seat === true;",
  "  const g = u.gateway_seat === true;",
  "  switch (seatType) {",
  "    case 'Access':  return a;",
  "    case 'Gateway': return g;",
  "    case 'Both':    return a && g;",
  "    default:        return a || g; // Either",
  "  }",
  "}",
  "function matches(u, t) {",
  "  const tl = t.toLowerCase();",
  "  if (t.indexOf('@') >= 0) return String(u.email || '').toLowerCase() === tl;",
  "  return [u.seat_uid, u.uid, u.id].some(function (v) { return v != null && String(v).toLowerCase() === tl; });",
  "}",
  "",
  "let pending = JSON.parse(pm.collectionVariables.get('_lmPending') || '[]');",
  "let flagged = JSON.parse(pm.collectionVariables.get('flaggedSeats') || '[]');",
  "let noSeat  = JSON.parse(pm.collectionVariables.get('_lmNoSeat') || '[]');",
  "",
  "(res.result || []).forEach(function (u) {",
  "  for (let i = pending.length - 1; i >= 0; i--) {",
  "    if (!matches(u, pending[i])) continue;",
  "    const t = pending[i];",
  "    pending.splice(i, 1);",
  "    if (holdsTarget(u) && u.seat_uid) {",
  "      if (!flagged.some(function (f) { return f.seat_uid === u.seat_uid; })) {",
  "        flagged.push({ seat_uid: u.seat_uid, email: u.email, basis: 'user-list' });",
  "      }",
  "    } else {",
  "      noSeat.push(t);",
  "    }",
  "  }",
  "});",
  "pm.collectionVariables.set('_lmPending', JSON.stringify(pending));",
  "pm.collectionVariables.set('flaggedSeats', JSON.stringify(flagged));",
  "pm.collectionVariables.set('_lmNoSeat', JSON.stringify(noSeat));",
  "",
  "const info = res.result_info || {};",
  "const page = parseInt(pm.collectionVariables.get('_page') || '1', 10);",
  "const totalPages = parseInt(info.total_pages || 1, 10);",
  "console.log('Scanned page ' + page + '/' + totalPages + ' - flagged ' + flagged.length + ' seat(s), ' + pending.length + ' unresolved');",
  "if (page < totalPages) {",
  "  pm.collectionVariables.set('_page', String(page + 1));",
  "  postman.setNextRequest(pm.info.requestName);",
  "} else {",
  "  pm.collectionVariables.unset('_page');",
  "  const body = flagged.map(function (c) { return { seat_uid: c.seat_uid, access_seat: false, gateway_seat: false }; });",
  "  pm.collectionVariables.set('removalBody', JSON.stringify(body));",
  "  console.log('RESOLUTION COMPLETE. ' + flagged.length + ' seat(s) flagged for removal.');",
  "  if (flagged.length) { console.log(JSON.stringify(flagged, null, 2)); }",
  "  if (noSeat.length)  { console.warn('Matched but holding no ' + seatType + ' seat (skipped): ' + noSeat.join(', ')); }",
  "  if (pending.length) { console.warn('Not found in account (skipped): ' + pending.join(', ')); }",
  "}",
];

// ---------------------------------------------------------------------------
// Shared: preview + guarded remove (both modes populate `flaggedSeats`)
// ---------------------------------------------------------------------------
const previewPreReq = [
  "const collected = JSON.parse(pm.collectionVariables.get('flaggedSeats') || '[]');",
  "console.log('=== Seats flagged for removal (' + collected.length + ') ===');",
  "if (collected.length) { console.log(JSON.stringify(collected, null, 2)); }",
  "else { console.log('None flagged. Run the List & Flag / Resolve request in this folder first (use the Collection Runner so pagination completes).'); }",
];

const previewTest = [
  "const res = pm.response.json();",
  "pm.test('API token is valid and active', function () {",
  "  pm.expect(res.success).to.be.true;",
  "});",
  "console.log('Token status:', res.result ? res.result.status : 'unknown');",
];

const removePreReq = [
  "// Safety guard: refuse to run unless the operator explicitly opts in.",
  "if (String(pm.collectionVariables.get('confirmRemoval')).toLowerCase() !== 'true') {",
  "  throw new Error(\"Refusing to remove seats. Set collection variable 'confirmRemoval' to 'true' to proceed.\");",
  "}",
  "const collected = JSON.parse(pm.collectionVariables.get('flaggedSeats') || '[]');",
  "if (!collected.length) { throw new Error('No seats flagged. Run the List & Flag / Resolve request in this folder first.'); }",
  "const body = collected.map(function (c) {",
  "  return { seat_uid: c.seat_uid, access_seat: false, gateway_seat: false };",
  "});",
  "pm.collectionVariables.set('removalBody', JSON.stringify(body));",
  "console.warn('Removing ' + body.length + ' seat(s) from account ' + pm.collectionVariables.get('accountId') + '...');",
];

const removeTest = [
  "const res = pm.response.json();",
  "pm.test('Seat removal succeeded', function () {",
  "  pm.expect(pm.response.code).to.eql(200);",
  "  pm.expect(res.success).to.be.true;",
  "});",
  "console.log('Seats updated:', res.result ? res.result.length : 0);",
  "// Reset the guard so a second run must be re-authorised.",
  "pm.collectionVariables.set('confirmRemoval', 'false');",
];

function event(listen, exec) {
  return { listen, script: { type: "text/javascript", exec } };
}

function urlObj(rawPath, query) {
  const u = {
    raw: "{{baseUrl}}/" + rawPath + (query && query.length ? "?" + query.map(q => q.key + "=" + q.value).join("&") : ""),
    host: ["{{baseUrl}}"],
    path: rawPath.split("/"),
  };
  if (query && query.length) u.query = query;
  return u;
}

const usersUrl = () => urlObj("accounts/{{accountId}}/access/users", [
  { key: "per_page", value: "1000" },
  { key: "page", value: "{{_page}}" },
]);

const previewReq = (name) => ({
  name,
  event: [event("prerequest", previewPreReq), event("test", previewTest)],
  request: {
    method: "GET", header: [], url: urlObj("user/tokens/verify", []),
    description: "Verifies the API token is active and prints the seats currently flagged for removal (from the List & Flag / Resolve request in this folder) to the Postman console. Changes nothing.",
  },
});

const removeReq = (name) => ({
  name,
  event: [event("prerequest", removePreReq), event("test", removeTest)],
  request: {
    method: "PATCH",
    header: [{ key: "Content-Type", value: "application/json" }],
    body: { mode: "raw", raw: "{{removalBody}}", options: { raw: { language: "json" } } },
    url: urlObj("accounts/{{accountId}}/access/seats", []),
    description: "DESTRUCTIVE. Frees every seat in `flaggedSeats` by setting access_seat and gateway_seat to false. Guarded: aborts unless `confirmRemoval` is 'true'. The guard resets to 'false' after a successful run.",
  },
});

const collection = {
  info: {
    name: "Cloudflare Access License Manager",
    _postman_id: "b0c1d2e3-4f56-4789-abcd-000000000001",
    description:
      "UNOFFICIAL / UNSUPPORTED: This is not a Cloudflare product and is not provided or supported by Cloudflare. Use at your own risk.\n\nFind Cloudflare Zero Trust (Access / Gateway) seat holders and free their seat licensing " +
      "(freeing a seat sets BOTH access_seat and gateway_seat to false, the only way Cloudflare " +
      "stops billing a seat).\n\n" +
      "SETUP: set the collection variables `accountId` and `apiToken` (a Cloudflare API token with " +
      "'Access: Audit Logs Read' and 'Zero Trust: Seats Write').\n\n" +
      "TWO MODES (run the folder for the mode you want, top to bottom, via the Collection Runner so " +
      "pagination completes):\n\n" +
      "1) Inactivity Mode - flag everyone whose last login is older than `inactiveDays` " +
      "(tune `seatType` and `excludeNeverLoggedIn`).\n" +
      "2) User-List Mode - flag an explicit set of users you provide in `userList` " +
      "(comma / space / newline separated emails, user IDs, or seat UIDs; `seatType` still applies).\n\n" +
      "In both modes: review with 'Verify Token & Preview', then set `confirmRemoval` = true and run " +
      "'Remove Flagged Seats'. The Utilities folder has standalone token-verify, single-page list, " +
      "and single-seat removal helpers.",
    schema: "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
  },
  auth: { type: "bearer", bearer: [{ key: "token", value: "{{apiToken}}", type: "string" }] },
  item: [
    {
      name: "Inactivity Mode",
      description: "Flag and remove seats whose last successful login is older than `inactiveDays`.",
      item: [
        {
          name: "1. List Users & Flag Inactive",
          event: [event("prerequest", inactivityPreReq), event("test", inactivityTest)],
          request: {
            method: "GET", header: [], url: usersUrl(),
            description: "Lists users and flags those whose last successful login is older than {{inactiveDays}} days (or who never logged in, unless excludeNeverLoggedIn=true), filtered by {{seatType}}. Flagged seats are stored in `flaggedSeats`. Run via the Collection Runner to auto-paginate accounts with >1000 users.",
          },
        },
        previewReq("2. Verify Token & Preview"),
        removeReq("3. Remove Flagged Seats"),
      ],
    },
    {
      name: "User-List Mode",
      description: "Flag and remove seats for an explicit list of users supplied in `userList`.",
      item: [
        {
          name: "1. Resolve User-List & Flag Seats",
          event: [event("prerequest", listResolvePreReq), event("test", listResolveTest)],
          request: {
            method: "GET", header: [], url: usersUrl(),
            description: "Reads `userList` (comma / space / newline separated emails, user IDs, or seat UIDs), pages through all users, and flags the seat held by each matching user (filtered by {{seatType}}). Entries that don't match a user, or match a user holding no matching seat, are reported to the console and skipped. Flagged seats are stored in `flaggedSeats`. Run via the Collection Runner so pagination completes.",
          },
        },
        previewReq("2. Verify Token & Preview"),
        removeReq("3. Remove Flagged Seats"),
      ],
    },
    {
      name: "Utilities",
      item: [
        {
          name: "Verify API Token",
          request: { method: "GET", header: [], url: urlObj("user/tokens/verify", []), description: "Confirms the token is valid and reports its status." },
        },
        {
          name: "List Users (single page)",
          request: {
            method: "GET", header: [],
            url: urlObj("accounts/{{accountId}}/access/users", [{ key: "per_page", value: "50" }, { key: "page", value: "1" }]),
            description: "Ad-hoc look at the first page of users with their seat + login fields.",
          },
        },
        {
          name: "Remove a Single Seat (manual)",
          request: {
            method: "PATCH",
            header: [{ key: "Content-Type", value: "application/json" }],
            body: { mode: "raw", raw: JSON.stringify([{ seat_uid: "{{seatUid}}", access_seat: false, gateway_seat: false }], null, 2), options: { raw: { language: "json" } } },
            url: urlObj("accounts/{{accountId}}/access/seats", []),
            description: "Frees a single seat by seat_uid. Set the `seatUid` collection variable first.",
          },
        },
      ],
    },
  ],
  variable: [
    { key: "baseUrl", value: "https://api.cloudflare.com/client/v4", type: "string" },
    { key: "accountId", value: "", type: "string" },
    { key: "apiToken", value: "", type: "string" },
    { key: "inactiveDays", value: "90", type: "string" },
    { key: "seatType", value: "Either", type: "string" },
    { key: "excludeNeverLoggedIn", value: "false", type: "string" },
    { key: "userList", value: "", type: "string" },
    { key: "confirmRemoval", value: "false", type: "string" },
    { key: "seatUid", value: "", type: "string" },
    { key: "flaggedSeats", value: "[]", type: "string" },
    { key: "removalBody", value: "[]", type: "string" },
  ],
};

const environment = {
  id: "e0c1d2e3-4f56-4789-abcd-000000000002",
  name: "Cloudflare Access License Manager - Example",
  values: [
    { key: "baseUrl", value: "https://api.cloudflare.com/client/v4", type: "default", enabled: true },
    { key: "accountId", value: "REPLACE_WITH_ACCOUNT_ID", type: "default", enabled: true },
    { key: "apiToken", value: "REPLACE_WITH_API_TOKEN", type: "secret", enabled: true },
    { key: "inactiveDays", value: "90", type: "default", enabled: true },
    { key: "seatType", value: "Either", type: "default", enabled: true },
    { key: "excludeNeverLoggedIn", value: "false", type: "default", enabled: true },
    { key: "userList", value: "", type: "default", enabled: true },
    { key: "confirmRemoval", value: "false", type: "default", enabled: true },
    { key: "seatUid", value: "", type: "default", enabled: true },
  ],
  _postman_variable_scope: "environment",
};

fs.writeFileSync(path.join(outDir, "CloudflareAccessLicenseManager.postman_collection.json"), JSON.stringify(collection, null, 2) + "\n");
fs.writeFileSync(path.join(outDir, "CloudflareAccessLicenseManager.postman_environment.json"), JSON.stringify(environment, null, 2) + "\n");
console.log("Wrote collection + environment to", outDir);

