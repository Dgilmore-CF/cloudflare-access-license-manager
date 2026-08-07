# Tests

End-to-end tests that exercise **both** tools against a local mock of the Cloudflare API
(`mock_cf.js`). No real Cloudflare account is contacted, and nothing is installed globally
by the tests themselves.

## Mock API

`mock_cf.js` is a tiny Node HTTP server (default port `8787`) that implements just enough of
the Cloudflare API for testing:

- `GET /accounts/:id/access/users` — returns 7 fixture users, **paginated 3 per page** so
  pagination logic is exercised (3 pages).
- `GET /user/tokens/verify` — returns an active-token response.
- `PATCH /accounts/:id/access/seats` — records each removal request to `patched.json`.

The 7 fixtures cover every branch: Access-only, Gateway-only, both seats, no seat, never
logged in (recent vs. long-provisioned), and a recently-active user.

## Run the PowerShell script tests

Requires `pwsh` (PowerShell 7+) and `node`.

```bash
./run_tests.sh
```

Covers: every `SeatType` filter, the `-ExcludeNeverLoggedIn` behavior, the `created_at`
fallback for never-logged-in users, that `-Remove` frees exactly the right seats with **both**
flags set to `false`, and that `-WhatIf` issues **no** PATCH.

## Run the Postman collection tests

Requires `newman` (`npm install -g newman`), `node`, and `jq`.

```bash
./run_postman_tests.sh
```

It points a temporary copy of the collection at the mock, runs it with newman, and asserts
that all in-collection tests pass and that the removal targeted exactly the inactive seats
with both flags `false`.
