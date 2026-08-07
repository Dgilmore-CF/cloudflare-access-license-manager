#Requires -Version 5.1
<#
.SYNOPSIS
    Find Cloudflare Zero Trust (Access / Gateway) seat holders who have not logged in
    within a configurable number of days and optionally free their seat licensing.

.DESCRIPTION
    Cloudflare Zero Trust bills per seat. A user consumes a seat once they authenticate
    with Access (access_seat = true) and/or log in to the WARP client (gateway_seat = true).

    This script lists every user for an account, flags those whose last successful login is
    older than -InactiveDays (or who have never logged in), and can free their seat by
    calling PATCH /accounts/{account_id}/access/seats with access_seat=false and
    gateway_seat=false -- which is the only way Cloudflare releases (stops billing) a seat.

    SAFE BY DEFAULT: without -Remove the script only reports candidates. -Remove performs
    the destructive removal and honours -WhatIf and -Confirm.

.PARAMETER AccountId
    Cloudflare account ID. Falls back to $env:CLOUDFLARE_ACCOUNT_ID.

.PARAMETER ApiToken
    Cloudflare API token. Falls back to $env:CLOUDFLARE_API_TOKEN.
    Required token permissions:
      - 'Access: Audit Logs Read'  (to list users)
      - 'Zero Trust: Seats Write'  (to remove seats)

.PARAMETER InactiveDays
    Days since last successful login after which a seat is considered inactive.

.PARAMETER SeatType
    Which seat holders to target:
      Access  - users holding an Access seat
      Gateway - users holding a Gateway (WARP) seat
      Either  - users holding an Access OR Gateway seat (default)
      Both    - users holding an Access AND Gateway seat

.PARAMETER Remove
    Actually remove seats. Omit for a report-only dry run.

.PARAMETER ExcludeNeverLoggedIn
    Skip users who have never logged in. By default such users are evaluated using their
    account creation date (created_at) as the reference time, so long-provisioned users who
    never signed in are treated as inactive.

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

.NOTES
    Freeing a seat sets BOTH access_seat and gateway_seat to false, per the Cloudflare
    seats API. There is no way to release only part of a seat.
    Docs: https://developers.cloudflare.com/api/resources/zero_trust/subresources/seats/
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $AccountId = $env:CLOUDFLARE_ACCOUNT_ID,
    [string] $ApiToken  = $env:CLOUDFLARE_API_TOKEN,

    [Parameter(Mandatory = $true)]
    [ValidateRange(0, 3650)]
    [int] $InactiveDays,

    [ValidateSet('Access', 'Gateway', 'Either', 'Both')]
    [string] $SeatType = 'Either',

    [switch] $Remove,
    [switch] $ExcludeNeverLoggedIn,

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
    $all = [System.Collections.Generic.List[object]]::new()
    $page = 1
    $perPage = 1000
    while ($true) {
        $uri = "$BaseUrl/accounts/$AccountId/access/users?per_page=$perPage&page=$page"
        $resp = Invoke-CfApi -Method GET -Uri $uri
        if (-not (Get-Prop $resp 'success' $false)) {
            throw "API error listing users: $((Get-Prop $resp 'errors') | ConvertTo-Json -Compress)"
        }
        foreach ($u in (Get-Prop $resp 'result' @())) { $all.Add($u) }

        $info = Get-Prop $resp 'result_info'
        $totalPages = [int](Get-Prop $info 'total_pages' 1)
        if ($totalPages -le $page) { break }
        $page++
    }
    return $all
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
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    try {
        return [datetime]::Parse(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
        )
    } catch { return $null }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host 'Cloudflare Access License Manager' -ForegroundColor Cyan
Write-Host ("Account : {0}" -f $AccountId)
Write-Host ("Criteria: inactive >= {0} day(s) | SeatType {1}" -f $InactiveDays, $SeatType)
$mode = if ($Remove) { 'REMOVE (seats will be freed)' } else { 'REPORT-ONLY (dry run)' }
Write-Host ("Mode    : {0}`n" -f $mode) -ForegroundColor $(if ($Remove) { 'Yellow' } else { 'Green' })

$nowUtc = (Get-Date).ToUniversalTime()
$cutoff = $nowUtc.AddDays(-$InactiveDays)

Write-Host 'Fetching users...' -ForegroundColor DarkGray
$users = Get-AccessUser
Write-Host ("Retrieved {0} user record(s).`n" -f $users.Count)

$candidates = [System.Collections.Generic.List[object]]::new()
foreach ($u in $users) {
    if (-not (Test-HoldsTargetSeat $u)) { continue }

    $seatUid = Get-Prop $u 'seat_uid'
    if ([string]::IsNullOrWhiteSpace($seatUid)) { continue }

    $basis = 'last_successful_login'
    $loginUtc = ConvertTo-Utc (Get-Prop $u 'last_successful_login')
    $ref = $loginUtc
    if ($null -eq $ref) {
        if ($ExcludeNeverLoggedIn) { continue }
        $ref = ConvertTo-Utc (Get-Prop $u 'created_at')
        $basis = 'created_at (never logged in)'
        if ($null -eq $ref) { continue }
    }

    if ($ref -lt $cutoff) {
        # Emit last_successful_login as a stable ISO-8601 UTC string so JSON and CSV
        # reports match and stay locale-independent (null stays null = never logged in).
        $loginIso = if ($null -ne $loginUtc) { $loginUtc.ToString('yyyy-MM-ddTHH:mm:ss\Z') } else { $null }
        $candidates.Add([pscustomobject]@{
            email                 = Get-Prop $u 'email'
            name                  = Get-Prop $u 'name'
            seat_uid              = $seatUid
            access_seat           = [bool](Get-Prop $u 'access_seat'  $false)
            gateway_seat          = [bool](Get-Prop $u 'gateway_seat' $false)
            last_successful_login = $loginIso
            days_inactive         = [int][math]::Floor(($nowUtc - $ref).TotalDays)
            basis                 = $basis
        })
    }
}

Write-Host ("Found {0} inactive seat holder(s) matching criteria.`n" -f $candidates.Count) -ForegroundColor Yellow

if ($candidates.Count -gt 0) {
    $candidates |
        Sort-Object days_inactive -Descending |
        Format-Table email, name, days_inactive, access_seat, gateway_seat, seat_uid -AutoSize |
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
