#Requires -Version 5.1
<#
.SYNOPSIS
    Find Cloudflare Zero Trust (Access / Gateway) seat holders - either those who have not
    logged in within a configurable number of days, or an explicit list of users you supply -
    and optionally free their seat licensing.

.DESCRIPTION
    Cloudflare Zero Trust bills per seat. A user consumes a seat once they authenticate
    with Access (access_seat = true) and/or log in to the WARP client (gateway_seat = true).

    This script lists every user for an account, selects seat holders to target, and can free
    their seat by calling PATCH /accounts/{account_id}/access/seats with access_seat=false and
    gateway_seat=false -- which is the only way Cloudflare releases (stops billing) a seat.

    SAFE BY DEFAULT: without -Remove the script only reports candidates. -Remove performs
    the destructive removal and honours -WhatIf and -Confirm.

    TWO SELECTION MODES:
      1. By inactivity (default) - supply -InactiveDays to target users whose most recent
         activity is older than the threshold. Activity is the LATER of:
           - last_successful_login  (last Cloudflare Access authentication), and
           - last_seen_at           (most recent WARP / Gateway device registration check-in)
         This mirrors how Cloudflare's own seat-expiration feature decides a user is inactive.
         Users with no activity at all are evaluated by their account creation date unless
         -ExcludeNeverLoggedIn is set.
      2. By explicit user list  - supply -UserList and/or -UserListPath to target a specific
         set of users (e.g. an offboarding list) regardless of activity. Entries may be
         email addresses or seat/user ids; they are matched against the account's users.

.PARAMETER AccountId
    Cloudflare account ID. Falls back to $env:CLOUDFLARE_ACCOUNT_ID.

.PARAMETER ApiToken
    Cloudflare API token. Falls back to $env:CLOUDFLARE_API_TOKEN.
    Required token permissions (Account scope):
      - 'Access: Users Read'       (to list users)
      - 'Zero Trust: Read'         (to read WARP device registrations for Gateway activity)
      - 'Zero Trust: Seats Write'  (to remove seats)

.PARAMETER InactiveDays
    Days since the user's most recent activity (Access login OR WARP device check-in) after
    which a seat is considered inactive.
    Used in the default (by-inactivity) mode; mutually exclusive with -UserList / -UserListPath.

.PARAMETER IgnoreDeviceActivity
    Inactivity mode only. Skip the WARP device-registration lookup and judge inactivity from
    last_successful_login (Access logins) alone. NOT RECOMMENDED: users who only use WARP
    will look as if they never logged in. Provided for tokens that lack 'Zero Trust: Read'.

.PARAMETER UserList
    One or more users to target explicitly, regardless of last-login activity. Each entry is
    an email address or a seat/user id. Accepts an array (-UserList a,b) or a single
    comma-separated string (-UserList "a,b"). Selects the by-user-list mode.

.PARAMETER UserListPath
    Path to a file listing users to target explicitly. Format is chosen by extension:
      .json - a JSON array of strings, or of objects with an email/seat_uid/uid/id field
      .csv  - rows with an email / seat_uid / uid / id column (case-insensitive header)
      other - plain text, one email or id per line ('#' begins a comment)
    Can be combined with -UserList; entries are merged and de-duplicated.

.PARAMETER SeatType
    Which seat holders to target:
      Access  - users holding an Access seat
      Gateway - users holding a Gateway (WARP) seat
      Either  - users holding an Access OR Gateway seat (default)
      Both    - users holding an Access AND Gateway seat

.PARAMETER Remove
    Actually remove seats. Omit for a report-only dry run.

.PARAMETER ExcludeNeverLoggedIn
    Skip users who have no recorded activity (no Access login and no WARP device check-in).
    By default such users are evaluated using their account creation date (created_at) as
    the reference time, so long-provisioned users who never signed in are treated as
    inactive. Applies to by-inactivity mode only.

.PARAMETER OutputPath
    Optional path to write the candidate/results report. Extension decides the format:
    .json writes JSON, anything else writes CSV.

.PARAMETER BatchSize
    Number of seats to remove per PATCH request (default 50).

.PARAMETER BaseUrl
    Cloudflare API base URL (default https://api.cloudflare.com/client/v4).

.EXAMPLE
    # Dry run: report users inactive for 90+ days holding any seat
    ./Remove-InactiveAccessSeats.ps1 -AccountId $env:CF_ACCT -ApiToken $env:CF_TOKEN -InactiveDays 90

.EXAMPLE
    # Remove Access seats for users inactive 180+ days and write a CSV report
    ./Remove-InactiveAccessSeats.ps1 -InactiveDays 180 -SeatType Access -Remove -OutputPath report.csv

.EXAMPLE
    # Preview exactly what -Remove would do without changing anything
    ./Remove-InactiveAccessSeats.ps1 -InactiveDays 60 -Remove -WhatIf

.EXAMPLE
    # Remove a specific list of offboarded users (by email), ignoring activity
    ./Remove-InactiveAccessSeats.ps1 -UserList alice@example.com,bob@example.com -Remove

.EXAMPLE
    # Remove every user named in a file (one email or id per line, or CSV, or JSON)
    ./Remove-InactiveAccessSeats.ps1 -UserListPath ./offboard.csv -Remove -OutputPath removed.json

.NOTES
    DISCLAIMER: This script is not a Cloudflare product and is not provided, endorsed,
    warrantied, or supported by Cloudflare, Inc. or Cloudflare support. Use at your
    own risk and review dry-run / -WhatIf output before removing seats.

    Freeing a seat sets BOTH access_seat and gateway_seat to false, per the Cloudflare
    seats API. There is no way to release only part of a seat.
    Docs: https://developers.cloudflare.com/api/resources/zero_trust/subresources/seats/
          https://developers.cloudflare.com/cloudflare-one/team-and-resources/users/seat-management/
#>
[CmdletBinding(DefaultParameterSetName = 'ByInactivity', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $AccountId = $env:CLOUDFLARE_ACCOUNT_ID,
    [string] $ApiToken  = $env:CLOUDFLARE_API_TOKEN,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByInactivity')]
    [ValidateRange(0, 3650)]
    [int] $InactiveDays,

    [Parameter(ParameterSetName = 'ByInactivity')]
    [switch] $ExcludeNeverLoggedIn,

    [Parameter(ParameterSetName = 'ByInactivity')]
    [switch] $IgnoreDeviceActivity,

    [Parameter(ParameterSetName = 'ByUserList')]
    [string[]] $UserList,

    [Parameter(ParameterSetName = 'ByUserList')]
    [string] $UserListPath,

    [ValidateSet('Access', 'Gateway', 'Either', 'Both')]
    [string] $SeatType = 'Either',

    [switch] $Remove,

    [string] $OutputPath,

    [ValidateRange(1, 100)]
    [int] $BatchSize = 50,

    [string] $BaseUrl = 'https://api.cloudflare.com/client/v4'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure TLS 1.2 on Windows PowerShell 5.1
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($AccountId)) {
    throw 'AccountId is required. Pass -AccountId or set $env:CLOUDFLARE_ACCOUNT_ID.'
}
if ([string]::IsNullOrWhiteSpace($ApiToken)) {
    throw 'ApiToken is required. Pass -ApiToken or set $env:CLOUDFLARE_API_TOKEN.'
}

$script:Headers = @{
    'Authorization' = "Bearer $ApiToken"
    'Content-Type'  = 'application/json'
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-Prop {
    # StrictMode-safe property access with a default.
    param($Object, [string] $Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties.Match($Name).Count -gt 0) {
        return $Object.$Name
    }
    return $Default
}

function Invoke-CfApi {
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Uri,
        [object] $Body
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $params = @{
                Method      = $Method
                Uri         = $Uri
                Headers     = $script:Headers
                ErrorAction = 'Stop'
            }
            if ($null -ne $Body) {
                $params['Body'] = ($Body | ConvertTo-Json -Depth 10 -Compress)
            }
            return Invoke-RestMethod @params
        }
        catch {
            $status = $null
            $resp = $_.Exception.Response
            if ($resp -and $resp.PSObject.Properties.Match('StatusCode').Count -gt 0) {
                try { $status = [int]$resp.StatusCode } catch { }
            }

            # Retry on rate limit
            if ($status -eq 429 -and $attempt -le 5) {
                $retryAfter = 2 * $attempt
                if ($resp) {
                    try {
                        $ra = $resp.Headers['Retry-After']
                        if ($ra) { $retryAfter = [int]$ra }
                    } catch { }
                }
                Write-Warning "Rate limited (HTTP 429). Retrying in $retryAfter s (attempt $attempt/5)..."
                Start-Sleep -Seconds $retryAfter
                continue
            }

            $detail = $null
            try { $detail = $_.ErrorDetails.Message } catch { }
            if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $_.Exception.Message }
            throw "Cloudflare API $Method $Uri failed (HTTP $status): $detail"
        }
    }
}

function Get-AccessUser {
    # GET /accounts/{id}/access/users is page-number paginated (per_page max 1000).
    # result_info.total_pages is not guaranteed to be present, so also derive the page
    # count from total_count/per_page and stop on a short or empty page.
    $all = [System.Collections.Generic.List[object]]::new()
    $page = 1
    $perPage = 1000
    while ($true) {
        $uri = "$BaseUrl/accounts/$AccountId/access/users?per_page=$perPage&page=$page"
        $resp = Invoke-CfApi -Method GET -Uri $uri
        if (-not (Get-Prop $resp 'success' $false)) {
            throw "API error listing users: $((Get-Prop $resp 'errors') | ConvertTo-Json -Compress)"
        }
        $batch = @(Get-Prop $resp 'result' @())
        foreach ($u in $batch) { $all.Add($u) }

        $info = Get-Prop $resp 'result_info'
        $totalPages = [int](Get-Prop $info 'total_pages' 0)
        if ($totalPages -le 0) {
            $totalCount = [int](Get-Prop $info 'total_count' 0)
            $pp         = [int](Get-Prop $info 'per_page' $perPage)
            if ($totalCount -gt 0 -and $pp -gt 0) {
                $totalPages = [int][math]::Ceiling($totalCount / $pp)
            }
        }

        if ($totalPages -gt 0) {
            if ($page -ge $totalPages) { break }
        } else {
            # No usable pagination metadata: keep going until a page comes back empty.
            if ($batch.Count -eq 0) { break }
        }
        if ($page -ge 100000) { throw 'Pagination did not terminate while listing users.' }
        $page++
    }
    return $all
}

function Get-DeviceLastSeen {
    # Build a lookup of most-recent WARP/Gateway activity per user from
    # GET /accounts/{id}/devices/registrations (cursor paginated). Each registration
    # carries user.id / user.email and last_seen_at. Returns a hashtable keyed by
    # lower-case user id AND lower-case email -> [datetime] (UTC) of the latest check-in.
    #
    # status=all is deliberate: a revoked/deleted registration still proves the user was
    # active at last_seen_at, and being conservative here avoids freeing a live seat.
    $seen = @{}
    $cursor = $null
    $pages = 0
    while ($true) {
        $uri = "$BaseUrl/accounts/$AccountId/devices/registrations?per_page=1000&status=all"
        if (-not [string]::IsNullOrWhiteSpace($cursor)) {
            $uri += "&cursor=$([uri]::EscapeDataString($cursor))"
        }
        $resp = Invoke-CfApi -Method GET -Uri $uri
        if (-not (Get-Prop $resp 'success' $false)) {
            throw "API error listing device registrations: $((Get-Prop $resp 'errors') | ConvertTo-Json -Compress)"
        }
        $batch = @(Get-Prop $resp 'result' @())
        foreach ($r in $batch) {
            $ts = ConvertTo-Utc (Get-Prop $r 'last_seen_at')
            if ($null -eq $ts) { continue }
            $usr = Get-Prop $r 'user'
            if ($null -eq $usr) { continue }
            foreach ($k in @((Get-Prop $usr 'id'), (Get-Prop $usr 'email'))) {
                if ([string]::IsNullOrWhiteSpace($k)) { continue }
                $key = ([string]$k).ToLowerInvariant()
                if (-not $seen.ContainsKey($key) -or $seen[$key] -lt $ts) { $seen[$key] = $ts }
            }
        }

        $info = Get-Prop $resp 'result_info'
        $next = Get-Prop $info 'cursor'
        $pages++
        if ([string]::IsNullOrWhiteSpace($next) -or $batch.Count -eq 0 -or $next -eq $cursor) { break }
        if ($pages -ge 100000) { throw 'Pagination did not terminate while listing device registrations.' }
        $cursor = $next
    }
    return $seen
}

function Get-UserDeviceSeen {
    # Latest device check-in for a user from the Get-DeviceLastSeen map, matched by
    # id, uid, then email (all lower-cased). Returns $null if the user has no devices.
    param($User, [hashtable] $SeenMap)
    $best = $null
    foreach ($k in @((Get-Prop $User 'id'), (Get-Prop $User 'uid'), (Get-Prop $User 'email'))) {
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        $key = ([string]$k).ToLowerInvariant()
        if ($SeenMap.ContainsKey($key)) {
            $v = $SeenMap[$key]
            if ($null -eq $best -or $v -gt $best) { $best = $v }
        }
    }
    return $best
}

function Test-HoldsTargetSeat {
    param($User)
    $access  = [bool](Get-Prop $User 'access_seat'  $false)
    $gateway = [bool](Get-Prop $User 'gateway_seat' $false)
    switch ($SeatType) {
        'Access'  { return $access }
        'Gateway' { return $gateway }
        'Both'    { return ($access -and $gateway) }
        default   { return ($access -or $gateway) }  # Either
    }
}

function ConvertTo-Utc {
    # Normalise an API timestamp to a UTC [datetime]. Accepts either the raw ISO-8601
    # string (Windows PowerShell 5.1 leaves JSON dates as strings) or a [datetime] /
    # [DateTimeOffset] (PowerShell 7's ConvertFrom-Json converts them automatically).
    # Avoids a culture-dependent string round-trip. Returns $null when absent/unparseable.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) {
        switch ($Value.Kind) {
            'Utc'   { return $Value }
            'Local' { return $Value.ToUniversalTime() }
            default { return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        }
    }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    try {
        return [datetime]::Parse(
            $s,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
        )
    } catch { return $null }
}

function Format-UtcIso {
    param($Value)
    if ($null -eq $Value) { return $null }
    return ([datetime]$Value).ToString('yyyy-MM-ddTHH:mm:ss\Z')
}

function Get-TargetList {
    # Build the de-duplicated list of target tokens (emails and/or ids) from an inline
    # array and/or a file. File format is chosen by extension:
    #   .json - array of strings, or array of objects with email/seat_uid/uid/id
    #   .csv  - rows with an email/seat_uid/uid/id column (case-insensitive header)
    #   other - plain text, one token per line ('#' starts a comment)
    param(
        [string[]] $InlineList,
        [string]   $Path
    )
    $tokens = [System.Collections.Generic.List[string]]::new()

    # Accept both a real array (-UserList a,b from within PowerShell) and a single
    # comma-separated string (-UserList "a,b" via -File, which does not auto-split).
    # Emails and seat/user ids never contain commas, so splitting on ',' is safe.
    foreach ($x in $InlineList) {
        if ([string]::IsNullOrWhiteSpace($x)) { continue }
        foreach ($piece in ($x -split ',')) {
            $p = $piece.Trim()
            if (-not [string]::IsNullOrWhiteSpace($p)) { $tokens.Add($p) }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        if (-not (Test-Path -LiteralPath $Path)) {
            throw "UserListPath not found: $Path"
        }
        $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
        if ($ext -eq '.json') {
            $data = (Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json
            foreach ($item in @($data)) {
                if ($item -is [string]) {
                    if (-not [string]::IsNullOrWhiteSpace($item)) { $tokens.Add($item.Trim()) }
                } else {
                    foreach ($f in 'email', 'seat_uid', 'uid', 'id') {
                        $v = Get-Prop $item $f
                        if (-not [string]::IsNullOrWhiteSpace($v)) { $tokens.Add(([string]$v).Trim()); break }
                    }
                }
            }
        }
        elseif ($ext -eq '.csv') {
            foreach ($row in (Import-Csv -LiteralPath $Path)) {
                foreach ($f in 'email', 'seat_uid', 'uid', 'id') {
                    $col = $row.PSObject.Properties | Where-Object { $_.Name -ieq $f } | Select-Object -First 1
                    if ($col -and -not [string]::IsNullOrWhiteSpace($col.Value)) {
                        $tokens.Add(([string]$col.Value).Trim()); break
                    }
                }
            }
        }
        else {
            foreach ($line in (Get-Content -LiteralPath $Path)) {
                $l = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($l) -or $l.StartsWith('#')) { continue }
                $tokens.Add($l)
            }
        }
    }

    # De-duplicate case-insensitively, preserving first occurrence and original case.
    $seen = @{}
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($tk in $tokens) {
        $k = $tk.ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $out.Add($tk) }
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$byList = $PSCmdlet.ParameterSetName -eq 'ByUserList'

# Resolve the target list up front so we fail fast on a bad path / empty list.
$targets = @()
if ($byList) {
    $targets = @(Get-TargetList -InlineList $UserList -Path $UserListPath)
    if ($targets.Count -eq 0) {
        throw 'User-list mode selected but no users were supplied. Pass -UserList and/or -UserListPath (a .txt/.csv/.json file).'
    }
}

Write-Host 'Cloudflare Access License Manager' -ForegroundColor Cyan
Write-Host ("Account : {0}" -f $AccountId)
if ($byList) {
    Write-Host ("Criteria: explicit user list ({0} entries) | SeatType {1}" -f $targets.Count, $SeatType)
} else {
    $signals = if ($IgnoreDeviceActivity) { 'Access login only' } else { 'Access login OR WARP device check-in' }
    Write-Host ("Criteria: inactive >= {0} day(s) | SeatType {1} | activity = {2}" -f $InactiveDays, $SeatType, $signals)
    if ($IgnoreDeviceActivity) {
        Write-Warning 'IgnoreDeviceActivity set: WARP-only users will appear as never logged in. Review results carefully.'
    }
}
$mode = if ($Remove) { 'REMOVE (seats will be freed)' } else { 'REPORT-ONLY (dry run)' }
Write-Host ("Mode    : {0}`n" -f $mode) -ForegroundColor $(if ($Remove) { 'Yellow' } else { 'Green' })

$nowUtc = (Get-Date).ToUniversalTime()

Write-Host 'Fetching users...' -ForegroundColor DarkGray
$users = Get-AccessUser
Write-Host ("Retrieved {0} user record(s)." -f $users.Count)

# WARP / Gateway activity lives on device registrations, not on the user record.
$deviceSeen = @{}
if (-not $byList -and -not $IgnoreDeviceActivity) {
    Write-Host 'Fetching WARP device registrations (Gateway activity)...' -ForegroundColor DarkGray
    try {
        $deviceSeen = Get-DeviceLastSeen
    } catch {
        throw ("Could not read device registrations, so Gateway/WARP activity cannot be evaluated. " +
               "Grant the token 'Zero Trust: Read', or re-run with -IgnoreDeviceActivity to judge by Access logins only " +
               "(not recommended). Underlying error: {0}" -f $_.Exception.Message)
    }
    Write-Host ("Device activity found for {0} user identifier(s)." -f $deviceSeen.Count)
}
Write-Host ''

$candidates = [System.Collections.Generic.List[object]]::new()

if ($byList) {
    # ----- Explicit user-list mode -----
    # Build case-insensitive lookups so each supplied email / id resolves to a user.
    $byEmail = @{}
    $byId    = @{}
    foreach ($u in $users) {
        $em = Get-Prop $u 'email'
        if (-not [string]::IsNullOrWhiteSpace($em)) { $byEmail[$em.ToLowerInvariant()] = $u }
        foreach ($idField in 'seat_uid', 'uid', 'id') {
            $idv = Get-Prop $u $idField
            if (-not [string]::IsNullOrWhiteSpace($idv)) { $byId[[string]$idv] = $u }
        }
    }

    $unmatched = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($t in $targets) {
        $key = ([string]$t).Trim()
        if ([string]::IsNullOrWhiteSpace($key)) { continue }

        $u = if ($key -like '*@*') { $byEmail[$key.ToLowerInvariant()] } else { $byId[$key] }

        if ($null -eq $u) {
            $unmatched.Add([pscustomobject]@{ input = $key; reason = 'not found in account' })
            continue
        }
        if (-not (Test-HoldsTargetSeat $u)) {
            $unmatched.Add([pscustomobject]@{ input = $key; reason = "no matching $SeatType seat (already unlicensed)" })
            continue
        }
        $seatUid = Get-Prop $u 'seat_uid'
        if ([string]::IsNullOrWhiteSpace($seatUid)) {
            $unmatched.Add([pscustomobject]@{ input = $key; reason = 'user holds no seat_uid' })
            continue
        }
        if ($seen.ContainsKey($seatUid)) { continue }  # de-dupe if the list names a user twice
        $seen[$seatUid] = $true

        $loginUtc = ConvertTo-Utc (Get-Prop $u 'last_successful_login')
        $daysInactive = if ($null -ne $loginUtc) { [int][math]::Floor(($nowUtc - $loginUtc).TotalDays) } else { $null }
        $candidates.Add([pscustomobject]@{
            email                 = Get-Prop $u 'email'
            name                  = Get-Prop $u 'name'
            seat_uid              = $seatUid
            access_seat           = [bool](Get-Prop $u 'access_seat'  $false)
            gateway_seat          = [bool](Get-Prop $u 'gateway_seat' $false)
            last_successful_login = Format-UtcIso $loginUtc
            last_device_seen      = $null   # device activity is not evaluated in user-list mode
            last_activity         = Format-UtcIso $loginUtc
            days_inactive         = $daysInactive
            basis                 = 'user-list'
        })
    }

    if ($unmatched.Count -gt 0) {
        $noun = if ($unmatched.Count -eq 1) { 'entry' } else { 'entries' }
        Write-Host ("{0} supplied {1} could not be matched to a removable seat:" -f $unmatched.Count, $noun) -ForegroundColor DarkYellow
        $unmatched | Format-Table input, reason -AutoSize | Out-Host
    }
} else {
    # ----- Inactivity mode (default) -----
    $cutoff = $nowUtc.AddDays(-$InactiveDays)
    foreach ($u in $users) {
        if (-not (Test-HoldsTargetSeat $u)) { continue }

        $seatUid = Get-Prop $u 'seat_uid'
        if ([string]::IsNullOrWhiteSpace($seatUid)) { continue }

        # Most recent activity = the later of the Access login and any WARP device check-in.
        $loginUtc  = ConvertTo-Utc (Get-Prop $u 'last_successful_login')
        $deviceUtc = if ($IgnoreDeviceActivity) { $null } else { Get-UserDeviceSeen -User $u -SeenMap $deviceSeen }

        $ref   = $null
        $basis = $null
        if ($null -ne $loginUtc)  { $ref = $loginUtc;  $basis = 'last_successful_login' }
        if ($null -ne $deviceUtc -and ($null -eq $ref -or $deviceUtc -gt $ref)) {
            $ref = $deviceUtc; $basis = 'device_last_seen'
        }
        if ($null -eq $ref) {
            if ($ExcludeNeverLoggedIn) { continue }
            $ref = ConvertTo-Utc (Get-Prop $u 'created_at')
            $basis = 'created_at (never logged in)'
            if ($null -eq $ref) { continue }
        }

        if ($ref -lt $cutoff) {
            # Emit timestamps as stable ISO-8601 UTC strings so JSON and CSV reports match
            # and stay locale-independent (null stays null = no such activity recorded).
            $candidates.Add([pscustomobject]@{
                email                 = Get-Prop $u 'email'
                name                  = Get-Prop $u 'name'
                seat_uid              = $seatUid
                access_seat           = [bool](Get-Prop $u 'access_seat'  $false)
                gateway_seat          = [bool](Get-Prop $u 'gateway_seat' $false)
                last_successful_login = Format-UtcIso $loginUtc
                last_device_seen      = Format-UtcIso $deviceUtc
                last_activity         = Format-UtcIso $ref
                days_inactive         = [int][math]::Floor(($nowUtc - $ref).TotalDays)
                basis                 = $basis
            })
        }
    }
}

$label = if ($byList) { 'listed seat holder(s) to remove' } else { 'inactive seat holder(s) matching criteria' }
Write-Host ("Found {0} {1}.`n" -f $candidates.Count, $label) -ForegroundColor Yellow

if ($candidates.Count -gt 0) {
    $candidates |
        Sort-Object days_inactive -Descending |
        Format-Table email, name, days_inactive, basis, access_seat, gateway_seat, seat_uid -AutoSize |
        Out-Host
}

# ---------------------------------------------------------------------------
# Report file
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $ext = [System.IO.Path]::GetExtension($OutputPath).ToLowerInvariant()
    if ($ext -eq '.json') {
        # -InputObject @(...) forces array output for 0 or 1 candidate and always
        # overwrites the file, so an empty run never leaves a stale report behind.
        $json = ConvertTo-Json -InputObject @($candidates) -Depth 5
        Set-Content -Path $OutputPath -Value $json -Encoding UTF8
    } else {
        $csv = @($candidates) | ConvertTo-Csv -NoTypeInformation
        Set-Content -Path $OutputPath -Value $csv -Encoding UTF8
    }
    Write-Host ("Report written to {0}`n" -f $OutputPath)
}

# ---------------------------------------------------------------------------
# Removal
# ---------------------------------------------------------------------------
if (-not $Remove) {
    Write-Host 'Dry run complete. Re-run with -Remove to free these seats.' -ForegroundColor Cyan
    return
}

if ($candidates.Count -eq 0) {
    Write-Host 'Nothing to remove.'
    return
}

$removed = 0
$failed  = 0
$results = [System.Collections.Generic.List[object]]::new()

$batches = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $candidates.Count; $i += $BatchSize) {
    $end = [math]::Min($i + $BatchSize, $candidates.Count) - 1
    $batches.Add(@($candidates[$i..$end]))
}

$batchNum = 0
foreach ($batch in $batches) {
    $batchNum++
    $target = "$($batch.Count) seat(s) [batch $batchNum/$($batches.Count)]"
    if ($PSCmdlet.ShouldProcess($target, 'Remove Zero Trust seat licensing')) {
        $body = @($batch | ForEach-Object {
            @{ seat_uid = $_.seat_uid; access_seat = $false; gateway_seat = $false }
        })
        try {
            $resp = Invoke-CfApi -Method PATCH -Uri "$BaseUrl/accounts/$AccountId/access/seats" -Body $body
            if (Get-Prop $resp 'success' $false) {
                $removed += $batch.Count
                foreach ($b in $batch) {
                    $results.Add([pscustomobject]@{ seat_uid = $b.seat_uid; email = $b.email; status = 'removed' })
                }
                Write-Host ("Batch {0}/{1}: removed {2} seat(s)." -f $batchNum, $batches.Count, $batch.Count) -ForegroundColor Green
            } else {
                $failed += $batch.Count
                Write-Warning ("Batch {0} API error: {1}" -f $batchNum, ((Get-Prop $resp 'errors') | ConvertTo-Json -Compress))
                foreach ($b in $batch) {
                    $results.Add([pscustomobject]@{ seat_uid = $b.seat_uid; email = $b.email; status = 'failed' })
                }
            }
        } catch {
            $failed += $batch.Count
            Write-Warning ("Batch {0} failed: {1}" -f $batchNum, $_.Exception.Message)
            foreach ($b in $batch) {
                $results.Add([pscustomobject]@{ seat_uid = $b.seat_uid; email = $b.email; status = 'failed' })
            }
        }
    }
}

Write-Host ("`nDone. Removed: {0} | Failed: {1}" -f $removed, $failed) -ForegroundColor Green

# Append results to the report when JSON output was requested
if (-not [string]::IsNullOrWhiteSpace($OutputPath) -and
    [System.IO.Path]::GetExtension($OutputPath).ToLowerInvariant() -eq '.json') {
    $resultsPath = [System.IO.Path]::ChangeExtension($OutputPath, '.results.json')
    $resultsJson = ConvertTo-Json -InputObject @($results) -Depth 5
    Set-Content -Path $resultsPath -Value $resultsJson -Encoding UTF8
    Write-Host ("Removal results written to {0}" -f $resultsPath)
}

