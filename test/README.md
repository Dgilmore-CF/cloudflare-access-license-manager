# Tests

End-to-end tests that exercise **both** tools against a local mock of the Cloudflare API
(`mock_cf.js`). No real Cloudflare account is contacted, and nothing is installed globally
by the tests themselves.

## Mock API

`mock_cf.js` is a tiny Node HTTP server (default port `8787`) that implements just enough of
the Cloudflare API for testing:

- `GET /accounts/:id/access/users` — returns 10 fixture users, **page-number paginated 3 per
  page** so pagination logic is exercised (4 pages). `last_successful_login` here reflects
  Access logins only, as in the real API.
- `GET /accounts/:id/devices/registrations` — returns 7 WARP device registrations
  (`user`, `last_seen_at`, `revoked_at`), **cursor paginated 4 per page**. This is where
  Gateway/WARP activity comes from.
- `GET /user/tokens/verify` — returns an active-token response.
- `PATCH /accounts/:id/access/seats` — records each removal request to `patched.json`.
- `POST /__reset` — test-only; clears the recorded PATCH log.

Special account IDs simulate real-world API variations:

| Account ID | Behaviour |
| --- | --- |
| `acct-nototal` | Users list omits `result_info.total_pages` (only `total_count`) — tools must still paginate fully. |
| `acct-nodev` | Device registrations endpoint returns **403** (token lacks `Zero Trust: Read`) — tools must abort unless device activity is explicitly ignored. |

The fixtures (documented in a table at the top of `mock_cf.js`) cover every branch:
Access-only, Gateway-only, both seats, no seat, never logged in (recent vs. long-provisioned),
a recently-active Access user, a **WARP-only user who is active** (must *not* be flagged),
a user with a **stale Access login but recent device activity** (must *not* be flagged),
a **device-only user whose device is stale** (flagged with `basis = device_last_seen`),
multiple registrations per user (newest wins), a revoked registration, a registration whose
`user.id` is null (email fallback, mixed case), and a registration with no `last_seen_at`.

## Run the PowerShell script tests

Requires `pwsh` (PowerShell 7+) and `node`.

```bash
./run_tests.sh
```

Covers: every `SeatType` filter, combining Access login with device `last_seen_at`, the
`basis` / `last_device_seen` / `last_activity` report columns, threshold boundaries, the
`-ExcludeNeverLoggedIn` behaviour, the `created_at` fallback for users with no activity,
`-IgnoreDeviceActivity` (legacy Access-only set), pagination without `total_pages`, fail-fast
on a device-registration 403, that `-Remove` frees exactly the right seats with **both** flags
set to `false`, that `-WhatIf` issues **no** PATCH, and all user-list mode input formats.

## Run the Postman collection tests

Requires `node` and `jq`. Uses a global `newman` if present, otherwise falls back to
`npx --yes newman` (downloaded on first use).

```bash
./run_postman_tests.sh
```

It points a temporary copy of the collection at the mock, runs each mode folder with newman,
and asserts that all in-collection tests pass and that the removal targeted exactly the
expected seats with both flags `false` — including the device-activity scan, pagination
without `total_pages`, and the device-403 abort / `ignoreDeviceActivity` override.
