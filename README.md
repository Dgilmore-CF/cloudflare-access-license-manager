# Cloudflare Access License Manager

> [!IMPORTANT]
> **Unofficial and unsupported:** This is a personal utility, not a Cloudflare product.
> It is not provided, endorsed, warrantied, or supported by Cloudflare, Inc. or Cloudflare support.
> Use at your own risk; it can remove Zero Trust seat licensing. Always review dry-run output before removal.

Find Cloudflare **Zero Trust** (Access / Gateway) seat holders and **free their seat
licensing** — so you stop paying for seats nobody uses. Target seats two ways:

- **By inactivity** — everyone who hasn't logged in within a configurable number of days.
- **By explicit user list** — a specific set of users you supply (offboarding, contractor
  cleanup, etc.), regardless of how recently they logged in.

Ships as two interchangeable tools that hit the same Cloudflare API:

| Tool | Path | Best for |
| --- | --- | --- |
| **PowerShell script** | [`scripts/Remove-InactiveAccessSeats.ps1`](scripts/Remove-InactiveAccessSeats.ps1) | Automation, scheduled cleanup, CI, CSV/JSON reporting |
| **Postman collection** | [`postman/`](postman/) | Interactive/manual review, teams that live in Postman |

> **Safe by default.** Both tools *report only* until you explicitly opt in to removal.
> The PowerShell script needs `-Remove`; the Postman collection needs `confirmRemoval = true`.

---

## How Cloudflare seat billing works

Cloudflare Zero Trust bills **per seat**. A user consumes a seat once they:

- authenticate with **Access** → `access_seat = true`, and/or
- log in to the **WARP** client (**Gateway**) → `gateway_seat = true`.

A seat is **released (billing stops) only when *both* `access_seat` and `gateway_seat`
are set to `false`.** There is no way to release "half" a seat. Both tools always send
both flags as `false` when freeing a seat, which is the only behavior the API supports.

**Inactivity mode** identifies inactivity from each user's `last_successful_login`:

- If `last_successful_login` is older than your `InactiveDays` threshold → **inactive**.
- If the user has **never logged in** (`last_successful_login` is null), the tool falls
  back to the account **creation date** (`created_at`), so long-provisioned users who
  never signed in are treated as inactive. Use `-ExcludeNeverLoggedIn` to skip them.

**User-list mode** ignores login activity entirely — it targets exactly the users you name
(still filtered by `-SeatType`). Entries that don't match any user, or match a user who
holds no matching seat, are reported and skipped.

---

## Prerequisites

- **PowerShell 5.1+** (Windows PowerShell) or **PowerShell 7+** (Windows/macOS/Linux) for the script.
- **[Postman](https://www.postman.com/)** or **[newman](https://github.com/postmanlabs/newman)** for the collection.
- A **Cloudflare API token** with:
  - `Access: Audit Logs Read` — to list users.
  - `Zero Trust: Seats Write` — to remove seats.
- Your **Cloudflare Account ID** (Dashboard → any Zero Trust page → the URL, or Account Home).

Create a token at **Cloudflare Dashboard → My Profile → API Tokens → Create Token → Custom token**.

---

## Quick start (PowerShell)

```powershell
# Provide credentials once (env vars are picked up automatically)
$env:CLOUDFLARE_ACCOUNT_ID = "<your-account-id>"
$env:CLOUDFLARE_API_TOKEN  = "<your-api-token>"
```

### Mode 1 — by inactivity

```powershell
# DRY RUN — report everyone inactive for 90+ days holding any seat
./scripts/Remove-InactiveAccessSeats.ps1 -InactiveDays 90

# Save a report you can review/share
./scripts/Remove-InactiveAccessSeats.ps1 -InactiveDays 90 -OutputPath report.json

# Preview exactly what removal WOULD do, without changing anything
./scripts/Remove-InactiveAccessSeats.ps1 -InactiveDays 90 -Remove -WhatIf

# Actually free the seats (prompts — it's a High-impact action; add -Confirm:$false to skip)
./scripts/Remove-InactiveAccessSeats.ps1 -InactiveDays 90 -Remove
```

### Mode 2 — by explicit user list

```powershell
# DRY RUN — target specific users by email, user id, or seat_uid
./scripts/Remove-InactiveAccessSeats.ps1 -UserList alice@example.com,bob@example.com

# From a file (.txt one-per-line, .csv, or .json — see examples/)
./scripts/Remove-InactiveAccessSeats.ps1 -UserListPath ./offboard.csv -OutputPath report.json

# Combine inline + file (merged and de-duplicated), then remove
./scripts/Remove-InactiveAccessSeats.ps1 -UserList carol@example.com -UserListPath ./offboard.csv -Remove

# Only free their Gateway (WARP) seat, leaving Access untouched is NOT possible —
# freeing always clears both flags; -SeatType filters WHICH users qualify, e.g.:
./scripts/Remove-InactiveAccessSeats.ps1 -UserListPath ./offboard.txt -SeatType Gateway -Remove
```

You can also pass credentials explicitly with `-AccountId` / `-ApiToken` instead of env vars.

### Parameters

| Parameter | Mode | Default | Description |
| --- | --- | --- | --- |
| `-AccountId` | both | `$env:CLOUDFLARE_ACCOUNT_ID` | Cloudflare account ID (flag or env var). |
| `-ApiToken` | both | `$env:CLOUDFLARE_API_TOKEN` | Cloudflare API token (flag or env var; permissions above). |
| `-InactiveDays` | inactivity | — | **Required in inactivity mode.** Days since last login before a seat is "inactive" (0–3650). |
| `-ExcludeNeverLoggedIn` | inactivity | off | Skip users who never logged in (default: treat them as inactive via `created_at`). |
| `-UserList` | user-list | — | Users to target: an array (`a,b`) or one comma-separated string (`"a,b"`). Each entry is an email, user id, or seat_uid. |
| `-UserListPath` | user-list | — | File of users: `.txt` (one per line, `#` comments), `.csv`, or `.json`. Merged with `-UserList`. |
| `-SeatType` | both | `Either` | `Access`, `Gateway`, `Either` (Access **or** Gateway), or `Both` (Access **and** Gateway). |
| `-Remove` | both | off | Actually free seats. Omit for a report-only dry run. Supports `-WhatIf` / `-Confirm`. |
| `-OutputPath` | both | — | Write a report. `*.json` → JSON, anything else → CSV. Removal also writes `*.results.json`. |
| `-BatchSize` | both | `50` | Seats removed per PATCH request (1–100). |
| `-BaseUrl` | both | `https://api.cloudflare.com/client/v4` | Override the API base (useful for testing). |

Inactivity mode (`-InactiveDays`, `-ExcludeNeverLoggedIn`) and user-list mode
(`-UserList`, `-UserListPath`) are **mutually exclusive** — the script enforces this via
PowerShell parameter sets. `-Remove` declares `ConfirmImpact = 'High'`, so it prompts
before removing unless you pass `-Confirm:$false`.

### `-UserListPath` file formats

- **`.txt`** — one entry per line; blank lines and lines starting with `#` are ignored.
- **`.csv`** — a header row with any of the columns `email`, `seat_uid`, `uid`, or `id`
  (matched case-insensitively; the first non-empty of those wins per row).
- **`.json`** — an array of strings, or an array of objects each carrying one of
  `email` / `seat_uid` / `uid` / `id`.

Entries are de-duplicated case-insensitively. See [`examples/`](examples/) for a template of
each format (`user-list.txt`, `user-list.csv`, `user-list.json`).

### `SeatType` semantics (both modes)

| Value | Targets users holding… |
| --- | --- |
| `Access` | an Access seat (`access_seat = true`) |
| `Gateway` | a Gateway/WARP seat (`gateway_seat = true`) |
| `Either` *(default)* | an Access **or** Gateway seat |
| `Both` | an Access **and** Gateway seat |

### Reports

`-OutputPath report.json` writes the candidate list as JSON (always a JSON array, even for
0 or 1 result). Any other extension writes CSV. When you use `-Remove`, a companion
`report.results.json` records the per-seat outcome (`removed` / `failed`). The `basis`
column shows why each seat was flagged (`last_successful_login`, `created_at (never logged
in)`, or `user-list`). Dates are stable ISO-8601 UTC strings so JSON and CSV agree. See
[`examples/`](examples/) for sample report + console output for both modes.

---

## Quick start (Postman)

1. Import both files from [`postman/`](postman/):
   - `CloudflareAccessLicenseManager.postman_collection.json`
   - `CloudflareAccessLicenseManager.postman_environment.json`
2. Select the environment and fill in `accountId` and `apiToken`.
3. The collection has a folder per mode. **Run the folder for the mode you want, top to
   bottom, using the Collection Runner** (so pagination completes for accounts with >1000 users):

   **📁 Inactivity Mode** — tune `inactiveDays`, `seatType`, `excludeNeverLoggedIn`.
   1. *List Users & Flag Inactive* — pages through users and builds the removal set.
   2. *Verify Token & Preview* — confirms the token and prints what would be removed.
   3. *Remove Flagged Seats* — guarded by `confirmRemoval`.

   **📁 User-List Mode** — set `userList` (comma / space / newline separated emails, user
   IDs, or seat UIDs); `seatType` still applies.
   1. *Resolve User-List & Flag Seats* — matches your list against the account; unmatched
      entries are reported to the console and skipped.
   2. *Verify Token & Preview* — prints the seats that would be removed.
   3. *Remove Flagged Seats* — guarded by `confirmRemoval`.

4. To remove: set `confirmRemoval = true`, then run the mode's **Remove Flagged Seats**
   request. It frees every flagged seat (both flags → `false`) and resets the guard to
   `false` afterward, so a second run must be re-authorised.
5. A **📁 Utilities** folder provides standalone *Verify Token*, *List Users (single page)*,
   and *Remove a Single Seat (manual)* requests.

Both modes populate the same `flaggedSeats` variable, and the collection never mutates your
account until you deliberately set `confirmRemoval = true`.

> The collection JSON is generated from [`postman/build_postman.js`](postman/build_postman.js).
> If you edit request logic, change the builder and regenerate: `node postman/build_postman.js`.

---

## Testing

The [`test/`](test/) folder validates **both** tools and **both** modes end-to-end against a
local mock of the Cloudflare API (no real account touched):

```bash
./test/run_tests.sh          # PowerShell script  (needs: pwsh, node)
./test/run_postman_tests.sh  # Postman collection (needs: newman, node, jq)
```

See [`test/README.md`](test/README.md) for details. The PowerShell script is also clean under
[PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) using the bundled
[`PSScriptAnalyzerSettings.psd1`](PSScriptAnalyzerSettings.psd1).

---

## Repository layout

```
.
├── scripts/Remove-InactiveAccessSeats.ps1            # the PowerShell tool
├── postman/
│   ├── CloudflareAccessLicenseManager.postman_collection.json
│   ├── CloudflareAccessLicenseManager.postman_environment.json
│   └── build_postman.js                              # regenerates the collection JSON
├── examples/                                         # sample reports, console transcripts, user-list templates
├── test/                                             # mock API + end-to-end tests for both tools/modes
├── PSScriptAnalyzerSettings.psd1                     # lint settings
├── DISCLAIMER.md                                     # unofficial / unsupported notice
├── SUPPORT.md                                        # support boundaries
├── LICENSE
└── README.md
```

---

## API reference

- List users: `GET /accounts/{account_id}/access/users` (paginated, `per_page` up to 1000).
- Remove seats: `PATCH /accounts/{account_id}/access/seats` with a body of
  `[{ "access_seat": false, "gateway_seat": false, "seat_uid": "<uid>" }, ...]`.
- Verify token: `GET /user/tokens/verify`.

Docs: <https://developers.cloudflare.com/api/resources/zero_trust/subresources/seats/> and
<https://developers.cloudflare.com/cloudflare-one/identity/users/seat-management/>

---

## Disclaimer

This repository is a personal, community-maintained utility. It is **not a Cloudflare product** and is **not provided, endorsed, warrantied, or supported by Cloudflare, Inc. or Cloudflare support**. Cloudflare support is not responsible for installing, operating, troubleshooting, validating, or maintaining this code.

This tool **removes seat licensing**, which can sign affected users out of Zero Trust and stop their seat billing. Always run a dry run (and ideally `-WhatIf`) first and review the report before using `-Remove` / `confirmRemoval = true`. Provided as-is under the [MIT License](LICENSE). See [DISCLAIMER.md](DISCLAIMER.md) and [SUPPORT.md](SUPPORT.md).
