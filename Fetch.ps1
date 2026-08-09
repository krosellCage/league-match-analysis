# Fetch.ps1 - pull matches and cache them to disk.
#
# Everything is cached by match ID, so a second run makes zero network requests
# for games it already has.
#
#   $env:RIOT_API_KEY = 'RGAPI-...'
#   .\Fetch.ps1 -RiotId 'Name#TAG' -Platform tr1
#
# Set RIOT_ID and RIOT_PLATFORM in your environment to skip the parameters:
#   $env:RIOT_ID = 'Name#TAG'
#   $env:RIOT_PLATFORM = 'tr1'

param(
    [string]$RiotId,
    [string]$Platform,
    [int]$Count = 20,
    [int]$Queue = 420,          # 420 ranked solo/duo, 440 flex, 0 all queues
    [string]$DataDir = "$PSScriptRoot\data"
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Riot.ps1"

if ([string]::IsNullOrWhiteSpace($RiotId))   { $RiotId   = $env:RIOT_ID }
if ([string]::IsNullOrWhiteSpace($Platform)) { $Platform = $env:RIOT_PLATFORM }
if ([string]::IsNullOrWhiteSpace($Platform)) { $Platform = 'tr1' }

if ([string]::IsNullOrWhiteSpace($RiotId)) {
    throw @"
No Riot ID given.

  .\Fetch.ps1 -RiotId 'Name#TAG' -Platform tr1

or set it once for the session:

  `$env:RIOT_ID = 'Name#TAG'
"@
}

if ($RiotId -notmatch '^(.+)#(.+)$') {
    throw "RiotId must look like Name#TAG, got '$RiotId'"
}
$gameName = $Matches[1]
$tagLine  = $Matches[2]

Set-RiotPlatform -Platform $Platform
Write-Host "platform $(Get-RiotPlatform) -> routing $(Get-RiotRegional)" -ForegroundColor DarkGray

$matchDir    = Join-Path $DataDir 'matches'
$timelineDir = Join-Path $DataDir 'timelines'
foreach ($d in @($DataDir, $matchDir, $timelineDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

# --- account -------------------------------------------------------------
# The PUUID never changes, so there is no reason to ask for it twice.
$accountFile = Join-Path $DataDir 'account.json'
$account = $null
if (Test-Path $accountFile) {
    $cachedAccount = Get-Content $accountFile -Raw | ConvertFrom-Json
    if ($cachedAccount.gameName -eq $gameName -and $cachedAccount.tagLine -eq $tagLine) {
        $account = $cachedAccount
        Write-Host "account: $($account.gameName)#$($account.tagLine) (cached)" -ForegroundColor DarkGray
    }
}
if (-not $account) {
    Write-Host "resolving $RiotId ..." -ForegroundColor Cyan
    $account = Get-RiotAccount -GameName $gameName -TagLine $tagLine
    $account | ConvertTo-Json -Depth 10 | Set-Content $accountFile -Encoding UTF8
    Write-Host "account: $($account.gameName)#$($account.tagLine)" -ForegroundColor Green
}
$puuid = $account.puuid

# --- match list ----------------------------------------------------------
Write-Host "listing last $Count matches (queue $Queue) ..." -ForegroundColor Cyan
$ids = @(Get-MatchIds -Puuid $puuid -Count $Count -Queue $Queue)

if ($ids.Count -eq 0) {
    Write-Host "No matches returned. If you have not played this queue recently, try -Queue 0." -ForegroundColor Yellow
    return
}
Write-Host "$($ids.Count) match ids" -ForegroundColor Green

# --- match + timeline ----------------------------------------------------
$fetched = 0; $cached = 0; $failed = 0

foreach ($id in $ids) {
    $mFile = Join-Path $matchDir    "$id.json"
    $tFile = Join-Path $timelineDir "$id.json"

    $needMatch    = -not (Test-Path $mFile)
    $needTimeline = -not (Test-Path $tFile)

    if (-not $needMatch -and -not $needTimeline) { $cached++; continue }

    Write-Host "  $id" -NoNewline
    try {
        # Write to a temp file first so an interrupted run cannot leave a
        # half-written file that later looks like a valid cache entry.
        if ($needMatch) {
            $tmp = "$mFile.partial"
            Get-MatchRaw -MatchId $id | Set-Content $tmp -Encoding UTF8
            Move-Item $tmp $mFile -Force
            Write-Host " match" -NoNewline -ForegroundColor DarkGray
        }
        if ($needTimeline) {
            $tmp = "$tFile.partial"
            Get-TimelineRaw -MatchId $id | Set-Content $tmp -Encoding UTF8
            Move-Item $tmp $tFile -Force
            Write-Host " timeline" -NoNewline -ForegroundColor DarkGray
        }
        Write-Host ""
        $fetched++
    }
    catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
Write-Host "fetched $fetched, already cached $cached$(if ($failed) { ", failed $failed" })" -ForegroundColor Green
Write-Host "cache: $DataDir" -ForegroundColor DarkGray
Write-Host "next:  .\Analyze.ps1" -ForegroundColor Cyan
