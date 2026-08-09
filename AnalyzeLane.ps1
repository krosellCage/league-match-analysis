# AnalyzeLane.ps1 - lane analysis (mid / bot / top), companion to Analyze.ps1.
#
# The jungle detectors answer jungle questions. A laner lives or dies on the
# matchup against ONE opponent, so everything here is measured as a difference
# against the enemy in the same position.
#
#   .\AnalyzeLane.ps1 -DataDir .\data-someone -JsonOut summary.json

param(
    [string]$DataDir = "$PSScriptRoot\data",
    [double]$MinDurationMinutes = 8,
    [string]$JsonOut
)

$ErrorActionPreference = 'Stop'

function Get-FrameAt($frames, [long]$ms) {
    $best = $null
    foreach ($f in $frames) {
        if ([long]$f.timestamp -le $ms) { $best = $f } else { break }
    }
    if (-not $best -and $frames.Count -gt 0) { $best = $frames[0] }
    return $best
}
function Get-PF($frame, [int]$participantId) {
    if (-not $frame) { return $null }
    return $frame.participantFrames."$participantId"
}

$accountFile = Join-Path $DataDir 'account.json'
if (-not (Test-Path $accountFile)) { throw "No cached account in $DataDir" }
$acct  = Get-Content $accountFile -Raw | ConvertFrom-Json
$puuid = $acct.puuid

$matchDir    = Join-Path $DataDir 'matches'
$timelineDir = Join-Path $DataDir 'timelines'

$games = @()
$skipped = 0

foreach ($mf in (Get-ChildItem $matchDir -Filter *.json | Sort-Object Name)) {
    $matchId = $mf.BaseName
    $tf = Join-Path $timelineDir "$matchId.json"
    if (-not (Test-Path $tf)) { $skipped++; continue }

    $match    = Get-Content $mf.FullName -Raw | ConvertFrom-Json
    $timeline = Get-Content $tf -Raw | ConvertFrom-Json

    $me = $match.info.participants | Where-Object { $_.puuid -eq $puuid }
    if (-not $me) { $skipped++; continue }

    $dur = [double]$match.info.gameDuration
    if ($dur -gt 100000) { $dur = $dur / 1000.0 }
    if ($dur -lt ($MinDurationMinutes * 60)) { $skipped++; continue }
    $durMin = [math]::Max($dur / 60.0, 1.0)

    $role = [string]$me.teamPosition
    if ([string]::IsNullOrWhiteSpace($role)) { $role = 'UNKNOWN' }

    $myId   = [int]$me.participantId
    $myTeam = [int]$me.teamId

    # The direct opponent: same position, other team.
    $opp = $match.info.participants |
        Where-Object { [int]$_.teamId -ne $myTeam -and [string]$_.teamPosition -eq $role } |
        Select-Object -First 1

    $frames = $timeline.info.frames

    # Differences against that opponent at the two standard checkpoints.
    $diffs = @{}
    foreach ($mark in @(10, 15)) {
        $fr = Get-FrameAt $frames ($mark * 60 * 1000)
        $mp = Get-PF $fr $myId
        $op = if ($opp) { Get-PF $fr ([int]$opp.participantId) } else { $null }
        if ($mp -and $op -and [long]$fr.timestamp -ge (($mark - 1) * 60 * 1000)) {
            $diffs["gold$mark"] = [int]$mp.totalGold - [int]$op.totalGold
            $diffs["xp$mark"]   = [int]$mp.xp - [int]$op.xp
            $diffs["cs$mark"]   = ([int]$mp.minionsKilled + [int]$mp.jungleMinionsKilled) -
                                  ([int]$op.minionsKilled + [int]$op.jungleMinionsKilled)
        } else {
            $diffs["gold$mark"] = $null; $diffs["xp$mark"] = $null; $diffs["cs$mark"] = $null
        }
    }

    # Deaths inside the laning phase, where a lead is actually decided.
    $earlyDeaths = 0
    foreach ($f in $frames) {
        foreach ($ev in $f.events) {
            if ($ev.type -eq 'CHAMPION_KILL' -and [int]$ev.victimId -eq $myId -and [long]$ev.timestamp -le 900000) {
                $earlyDeaths++
            }
        }
    }

    $teamKills = 0
    $teamDamage = 0
    foreach ($p in $match.info.participants) {
        if ([int]$p.teamId -eq $myTeam) {
            $teamKills  += [int]$p.kills
            $teamDamage += [int]$p.totalDamageDealtToChampions
        }
    }

    $cs = [int]$me.totalMinionsKilled + [int]$me.neutralMinionsKilled
    $startMs = 0
    if ($match.info.PSObject.Properties['gameStartTimestamp']) { $startMs = [long]$match.info.gameStartTimestamp }

    $games += [pscustomobject][ordered]@{
        matchId      = $matchId
        startMs      = $startMs
        date         = if ($startMs -gt 0) { [DateTimeOffset]::FromUnixTimeMilliseconds($startMs).UtcDateTime.ToString('yyyy-MM-dd') } else { '' }
        role         = $role
        champion     = [string]$me.championName
        opponent     = if ($opp) { [string]$opp.championName } else { '' }
        win          = [bool]$me.win
        durationMin  = [math]::Round($durMin, 1)
        kills        = [int]$me.kills
        deaths       = [int]$me.deaths
        assists      = [int]$me.assists
        csPerMin     = [math]::Round($cs / $durMin, 2)
        visionPerMin = [math]::Round([double]$me.visionScore / $durMin, 2)
        dmgPerMin    = [int]([double]$me.totalDamageDealtToChampions / $durMin)
        dmgShare     = if ($teamDamage -gt 0) { [math]::Round([double]$me.totalDamageDealtToChampions / $teamDamage * 100, 0) } else { 0 }
        killParticipation = if ($teamKills -gt 0) { [math]::Round((([int]$me.kills + [int]$me.assists) / $teamKills) * 100, 0) } else { 0 }
        earlyDeaths  = $earlyDeaths
        goldDiff10   = $diffs['gold10']
        csDiff10     = $diffs['cs10']
        xpDiff10     = $diffs['xp10']
        goldDiff15   = $diffs['gold15']
        csDiff15     = $diffs['cs15']
    }
}

if ($games.Count -eq 0) { throw "No usable games found in $DataDir" }

$sorted = $games | Sort-Object startMs
$wins   = @($games | Where-Object { $_.win }).Count

function Avg($set, $prop) {
    $vals = @($set | Where-Object { $null -ne $_.$prop } | ForEach-Object { $_.$prop })
    if ($vals.Count -eq 0) { return $null }
    return ($vals | Measure-Object -Average).Average
}

$summary = [ordered]@{
    account      = "$($acct.gameName)#$($acct.tagLine)"
    games        = $games.Count
    skipped      = $skipped
    wins         = $wins
    losses       = $games.Count - $wins
    winRate      = [math]::Round($wins / $games.Count * 100, 0)
    firstDate    = $sorted[0].date
    lastDate     = $sorted[-1].date
    csPerMin     = [math]::Round((Avg $games 'csPerMin'), 2)
    visionPerMin = [math]::Round((Avg $games 'visionPerMin'), 2)
    killParticipation = [math]::Round((Avg $games 'killParticipation'), 0)
    deaths       = [math]::Round((Avg $games 'deaths'), 1)
    earlyDeaths  = [math]::Round((Avg $games 'earlyDeaths'), 2)
    dmgPerMin    = [int](Avg $games 'dmgPerMin')
    dmgShare     = [math]::Round((Avg $games 'dmgShare'), 0)
    goldDiff10   = [int](Avg $games 'goldDiff10')
    csDiff10     = [math]::Round((Avg $games 'csDiff10'), 1)
    xpDiff10     = [int](Avg $games 'xpDiff10')
    goldDiff15   = [int](Avg $games 'goldDiff15')
    csDiff15     = [math]::Round((Avg $games 'csDiff15'), 1)
    byRole       = @()
    byChampion   = @()
    trend        = @{}
    games_detail = $sorted
}

foreach ($g in ($games | Group-Object role | Sort-Object Count -Descending)) {
    $w = @($g.Group | Where-Object { $_.win }).Count
    $summary.byRole += [ordered]@{
        role = $g.Name; games = $g.Count; wins = $w; losses = $g.Count - $w
        winRate = [math]::Round($w / $g.Count * 100, 0)
        csPerMin = [math]::Round((Avg $g.Group 'csPerMin'), 2)
        goldDiff10 = [int](Avg $g.Group 'goldDiff10')
        deaths = [math]::Round((Avg $g.Group 'deaths'), 1)
        killParticipation = [math]::Round((Avg $g.Group 'killParticipation'), 0)
    }
}

foreach ($g in ($games | Group-Object champion | Sort-Object Count -Descending | Select-Object -First 12)) {
    $w = @($g.Group | Where-Object { $_.win }).Count
    $summary.byChampion += [ordered]@{
        champion = $g.Name; games = $g.Count; wins = $w; losses = $g.Count - $w
        winRate = [math]::Round($w / $g.Count * 100, 0)
        csPerMin = [math]::Round((Avg $g.Group 'csPerMin'), 2)
        goldDiff10 = [int](Avg $g.Group 'goldDiff10')
        deaths = [math]::Round((Avg $g.Group 'deaths'), 1)
    }
}

if ($sorted.Count -ge 6) {
    $h = [int][math]::Floor($sorted.Count / 2)
    $old = $sorted[0..($h-1)]; $new = $sorted[$h..($sorted.Count-1)]
    foreach ($p in @('csPerMin','visionPerMin','killParticipation','deaths','goldDiff10','earlyDeaths')) {
        $summary.trend[$p] = @{ older = [math]::Round((Avg $old $p), 2); newer = [math]::Round((Avg $new $p), 2) }
    }
    $summary.trend['record'] = @{
        older = "$(@($old | Where-Object { $_.win }).Count)-$($old.Count - @($old | Where-Object { $_.win }).Count)"
        newer = "$(@($new | Where-Object { $_.win }).Count)-$($new.Count - @($new | Where-Object { $_.win }).Count)"
    }
}

if ($JsonOut) {
    $summary | ConvertTo-Json -Depth 12 | Set-Content $JsonOut -Encoding UTF8
    Write-Host "written to $JsonOut" -ForegroundColor Green
}
$summary | ConvertTo-Json -Depth 4 -Compress:$false | Select-Object -First 0 | Out-Null

# console summary
"ACCOUNT      $($summary.account)"
"GAMES        $($summary.games) ($($summary.wins)W-$($summary.losses)L, $($summary.winRate)%)  $($summary.firstDate) -> $($summary.lastDate)"
"CS/MIN       $($summary.csPerMin)"
"GOLD DIFF10  $($summary.goldDiff10)   CS DIFF10 $($summary.csDiff10)   XP DIFF10 $($summary.xpDiff10)"
"GOLD DIFF15  $($summary.goldDiff15)   CS DIFF15 $($summary.csDiff15)"
"DEATHS       $($summary.deaths)  (early $($summary.earlyDeaths))"
"KP / VISION  $($summary.killParticipation)% / $($summary.visionPerMin)"
"DAMAGE       $($summary.dmgPerMin)/min, $($summary.dmgShare)% of team"
""
"BY ROLE"
$summary.byRole | ForEach-Object { "  {0,-8} {1,3}g  {2}W-{3}L ({4}%)  cs {5}  gd10 {6,6}  d {7}  kp {8}%" -f $_.role,$_.games,$_.wins,$_.losses,$_.winRate,$_.csPerMin,$_.goldDiff10,$_.deaths,$_.killParticipation }
""
"BY CHAMPION"
$summary.byChampion | ForEach-Object { "  {0,-14} {1,3}g  {2}W-{3}L ({4}%)  cs {5}  gd10 {6,6}  d {7}" -f $_.champion,$_.games,$_.wins,$_.losses,$_.winRate,$_.csPerMin,$_.goldDiff10,$_.deaths }
""
"TREND"
$summary.trend.GetEnumerator() | Sort-Object Name | ForEach-Object { "  {0,-18} {1}  ->  {2}" -f $_.Name, $_.Value.older, $_.Value.newer }
