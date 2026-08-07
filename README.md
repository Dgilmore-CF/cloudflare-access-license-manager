# Cloudflare Access License Manager

Find Cloudflare **Zero Trust** (Access / Gateway) seat holders who haven't logged in
within a configurable number of days and **free their seat licensing** — so you stop
paying for seats nobody uses.

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

The tool identifies inactivity from each user's `last_successful_login`:

- If `last_successful_login` is older than your `InactiveDays` threshold → **inactive**.
- If the user has **never logged in** (`last_successful_login` is null), the tool falls
  back to the account **creation date** (`created_at`), so long-provisioned users who
  never signed in are treated as inactive. Use `-ExcludeNeverLoggedIn` to skip them.

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
# 1) Provide credentials (env vars are picked up automatically)
$env:CLOUDFLARE_ACCOUNT_ID = "<your-account-id>"
$env:CLOUDFLARE_API_TOKEN  = "<your-api-token>"

# 2) DRY RUN — report everyone inactive for 90+ days holding any seat
./scripts/Remove-InactiveAccessSeats.ps1 -InactiveDays 90

# 3) Save a report you can review/share
./scripts/Remove-InactiveAccessSeats.ps1 -InactiveDays 90 -OutputPath report.json

# 4) Preview exactly what removal WOULD do, without changing anything
./scripts/Remove-InactiveAccessSeats.ps1 -InactiveDays 90 -Remove -WhatIf

# 5) Actually free the seats (prompts for confirmation — it's a High-impact action)
./scripts/Remove-InactiveAccessSeats.ps1 -InactiveDays 90 -Remove

# ...or skip the prompt in automation
./scripts/Remove-InactiveAccessSeats.ps1 -InactiveDays 90 -Remove -Confirm:$false
```

You can also pass credentials explicitly with `-AccountId` / `-ApiToken` instead of env vars.

### Parameters

| Parameter | Required | Default | Description |
| --- | --- | --- | --- |
| `-AccountId` | yes* | `$env:CLOUDFLARE_ACCOUNT_ID` | Cloudflare account ID. |
| `-ApiToken` | yes* | `$env:CLOUDFLARE_API_TOKEN` | Cloudflare API token (see permissions above). |
| `-InactiveDays` | **yes** | — | Days since last login before a seat is "inactive" (0–3650). |
| `-SeatType` | no | `Either` | `Access`, `Gateway`, `Either` (Access **or** Gateway), or `Both` (Access **and** Gateway). |
| `-Remove` | no | off | Actually free seats. Omit for a report-only dry run. |
| `-ExcludeNeverLoggedIn` | no | off | Skip users who never logged in (default: treat them as inactive via `created_at`). |
| `-OutputPath` | no | — | Write a report. `*.json` → JSON, anything else → CSV. Removal also writes `*.results.json`. |
| `-BatchSize` | no | `50` | Seats removed per PATCH request (1–100). |
| `-BaseUrl` | no | `https://api.cloudflare.com/client/v4` | Override the API base (useful for testing). |

\* Required via the flag **or** the corresponding environment variable.

`-Remove` supports the standard PowerShell safety switches **`-WhatIf`** and **`-Confirm`**
(the script declares `ConfirmImpact = 'High'`, so it prompts before removing unless you pass `-Confirm:$false`).

### `SeatType` semantics

| Value | Targets users holding… |
| --- | --- |
| `Access` | an Access seat (`access_seat = true`) |
| `Gateway` | a Gateway/WARP seat (`gateway_seat = true`) |
| `Either` *(default)* | an Access **or** Gateway seat |
| `Both` | an Access **and** Gateway seat |

### Reports

`-OutputPath report.json` writes the candidate list as JSON (always a JSON array, even for
0 or 1 result). Any other extension writes CSV. When you use `-Remove`, a companion
`report.results.json` records the per-seat outcome (`removed` / `failed`). Dates are emitted
as stable ISO-8601 UTC strings so JSON and CSV agree and stay locale-independent. See
[`examples/`](examples/) for sample output.

---

## Quick start (Postman)

1. Import both files from [`postman/`](postman/):
   - `CloudflareAccessLicenseManager.postman_collection.json`
   - `CloudflareAccessLicenseManager.postman_environment.json`
2. Select the environment and fill in `accountId` and `apiToken`. Adjust `inactiveDays`,
   `seatType`, and `excludeNeverLoggedIn` as needed.
3. Run the requests **in order** (use the Collection Runner for pagination to work):
   1. **List & Flag Inactive Seats** — pages through all users and builds the removal set.
   2. **Verify Token & Preview Candidates** — confirms the token and shows what would be removed.
   3. **Remove Inactive Seats** — **guarded**: it refuses to run unless `confirmRemoval = true`,
      then frees every flagged seat (both flags → `false`) and resets the guard afterward.
4. A **Utilities** folder provides standalone *Verify Token*, *List Users (single page)*,
   and *Remove a Single Seat (manual)* requests.

The collection resolves everything through collection variables, so it never mutates your
account until you deliberately set `confirmRemoval = true`.

---

## Testing

The [`test/`](test/) folder validates **both** tools end-to-end against a local mock of the
Cloudflare API (no real account touched):

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
│   └── CloudflareAccessLicenseManager.postman_environment.json
├── examples/                                         # sample JSON/CSV reports + console output
├── test/                                             # mock API + end-to-end tests for both tools
├── PSScriptAnalyzerSettings.psd1                     # lint settings
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

This tool **removes seat licensing**, which signs affected users out of Zero Trust and stops
their seat billing. Always run a dry run (and ideally `-WhatIf`) first and review the report
before using `-Remove` / `confirmRemoval = true`. Provided as-is under the [MIT License](LICENSE);
it is not an official Cloudflare product.
