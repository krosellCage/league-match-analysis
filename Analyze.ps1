# Analyze.ps1 - Milestone M2: run detectors over the cached games.
#
# Every number printed here is computed from the timeline, not estimated.
# Nothing in this file talks to the network - it only reads .\data\.
#
#   .\Analyze.ps1
#   .\Analyze.ps1 -JungleOnly:$false

param(
    [string]$DataDir = "$PSScriptRoot\data",
    [switch]$JungleOnly = $true,
    [int]$SetupWindowSeconds = 60,      # the section 09 rule: 60s before the objective
    [int]$AtPitUnits = 2500,            # "you were there"
    [int]$NearbyUnits = 5500,           # "you were arriving"
    [double]$MinDurationMinutes = 8,    # anything shorter is a remake
    [string]$MarkdownOut                # optional path for a shareable report
)

$ErrorActionPreference = 'Stop'

# Summoner's Rift is roughly a 14870 x 14870 space with blue base bottom-left
# and red base top-right. The river runs along the anti-diagonal, so (x + y)
# is a clean scalar for "which half of the map is this in".
#
# Checked against 5820 real position samples: observed x 130..14589,
# y 135..14673, consistent with a ~14870 square. The constant is good to
# roughly +/-150 units, which is far below the scale anything here measures
# (jungle quadrants are thousands of units across), so it does not affect
# any verdict. Re-check if Riot ever reshapes the map.
$MIDLINE = 14870

function Get-Distance($a, $b) {
    if (-not $a -or -not $b) { return $null }
    $dx = [double]$a.x - [double]$b.x
    $dy = [double]$a.y - [double]$b.y
    return [math]::Sqrt($dx * $dx + $dy * $dy)
}

function Get-Depth($pos, $teamId) {
    # Positive = inside the ENEMY half. Negative = your own half.
    if (-not $pos) { return $null }
    $d = ([double]$pos.x + [double]$pos.y) - $MIDLINE
    if ($teamId -eq 200) { $d = -$d }
    return $d
}

function Get-FrameAt($frames, [long]$ms) {
    # Frames land once per minute, so anything we read here can be up to
    # 60 seconds stale. That staleness is reported, never hidden.
    $best = $null
    foreach ($f in $frames) {
        if ([long]$f.timestamp -le $ms) { $best = $f } else { break }
    }
    if (-not $best -and $frames.Count -gt 0) { $best = $frames[0] }
    return $best
}

function Get-PF($frame, [int]$participantId) {
    # NOTE: do not name this parameter $pid - that is a read-only automatic
    # variable in PowerShell (the process id) and assigning it throws.
    if (-not $frame) { return $null }
    return $frame.participantFrames."$participantId"
}

function Get-HpPct($pf) {
    if (-not $pf -or -not $pf.championStats) { return $null }
    $max = [double]$pf.championStats.healthMax
    if ($max -le 0) { return $null }
    return [int](([double]$pf.championStats.health / $max) * 100)
}

function Show-Trend {
    param($Older, $Newer, [string]$Label, [string]$Prop, [int]$Decimals, [bool]$HigherIsBetter)

    $o = ($Older | Measure-Object $Prop -Average).Average
    $n = ($Newer | Measure-Object $Prop -Average).Average
    if ($null -eq $o -or $null -eq $n) { return }

    $delta = $n - $o
    $flat  = [math]::Abs($delta) -lt 0.05
    $good  = if ($HigherIsBetter) { $delta -gt 0 } else { $delta -lt 0 }
    $arrow = if ($flat) { '=' } elseif ($delta -gt 0) { 'up' } else { 'down' }
    $col   = if ($flat) { 'DarkGray' } elseif ($good) { 'Green' } else { 'Red' }

    Write-Host ("  {0,-22} {1,8} {2,8}   {3}" -f $Label,
        [math]::Round($o, $Decimals), [math]::Round($n, $Decimals), $arrow) -ForegroundColor $col
}

function Format-Clock([long]$ms) {
    $t = [int]([math]::Floor($ms / 1000))
    return ('{0}:{1:d2}' -f [int]([math]::Floor($t / 60)), ($t % 60))
}

# -------------------------------------------------------------------------

$accountFile = Join-Path $DataDir 'account.json'
if (-not (Test-Path $accountFile)) { throw "No cached account. Run .\Fetch.ps1 first." }
$puuid = (Get-Content $accountFile -Raw | ConvertFrom-Json).puuid

$matchDir    = Join-Path $DataDir 'matches'
$timelineDir = Join-Path $DataDir 'timelines'
$matchFiles  = Get-ChildItem $matchDir -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name

if (-not $matchFiles) { throw "No cached matches in $matchDir. Run .\Fetch.ps1 first." }

$games      = @()
$allObj     = @()
$allDeaths  = @()
$allDuels   = @()

# Why games were left out, so the sample is never silently wrong.
$skipped = @{}
$skipped['not in match']        = 0
$skipped['remake / too short']  = 0
$skipped['no timeline cached']  = 0

foreach ($mf in $matchFiles) {
    $matchId = $mf.BaseName
    $tf = Join-Path $timelineDir "$matchId.json"
    if (-not (Test-Path $tf)) { $skipped['no timeline cached']++; continue }

    $match    = Get-Content $mf.FullName -Raw | ConvertFrom-Json
    $timeline = Get-Content $tf -Raw | ConvertFrom-Json

    $me = $match.info.participants | Where-Object { $_.puuid -eq $puuid }
    if (-not $me) { $skipped['not in match']++; continue }

    # Remakes and early surrenders would skew every average, so drop them.
    $rawDur = [double]$match.info.gameDuration
    if ($rawDur -gt 100000) { $rawDur = $rawDur / 1000.0 }   # older matches used ms
    if ($rawDur -lt ($MinDurationMinutes * 60)) { $skipped['remake / too short']++; continue }

    $role = $me.teamPosition
    if ([string]::IsNullOrWhiteSpace($role)) { $role = 'UNKNOWN' }
    if ($JungleOnly -and $role -ne 'JUNGLE') { $skipped["not jungle ($role)"]++; continue }

    $myId   = [int]$me.participantId
    $myTeam = [int]$me.teamId

    # participantId -> teamId, and -> champion name
    $teamOf = @{}
    $champOf = @{}
    $roleOf = @{}
    foreach ($p in $match.info.participants) {
        $teamOf[[int]$p.participantId]  = [int]$p.teamId
        $champOf[[int]$p.participantId] = [string]$p.championName
        $roleOf[[int]$p.participantId]  = [string]$p.teamPosition
    }

    $frames = $timeline.info.frames

    # gameDuration has been seconds in modern matches, ms in older ones.
    $durSec = [double]$match.info.gameDuration
    if ($durSec -gt 100000) { $durSec = $durSec / 1000.0 }
    $durMin = [math]::Max($durSec / 60.0, 1.0)

    $teamKills = 0
    foreach ($p in $match.info.participants) {
        if ([int]$p.teamId -eq $myTeam) { $teamKills += [int]$p.kills }
    }

    $cs = [int]$me.totalMinionsKilled + [int]$me.neutralMinionsKilled

    $kp = 0
    if ($teamKills -gt 0) {
        $kp = [math]::Round((([int]$me.kills + [int]$me.assists) / $teamKills) * 100, 0)
    }

    $startMs = 0
    if ($match.info.PSObject.Properties['gameStartTimestamp']) {
        $startMs = [long]$match.info.gameStartTimestamp
    } elseif ($match.info.PSObject.Properties['gameCreation']) {
        $startMs = [long]$match.info.gameCreation
    }

    $game = [ordered]@{
        matchId    = $matchId
        startMs    = $startMs
        startedUtc = if ($startMs -gt 0) { [DateTimeOffset]::FromUnixTimeMilliseconds($startMs).UtcDateTime.ToString('yyyy-MM-dd HH:mm') } else { '' }
        champion   = [string]$me.championName
        role       = $role
        win        = [bool]$me.win
        durationMin= [math]::Round($durMin, 1)
        kills      = [int]$me.kills
        deaths     = [int]$me.deaths
        assists    = [int]$me.assists
        csPerMin   = [math]::Round($cs / $durMin, 2)
        visionPerMin = [math]::Round([double]$me.visionScore / $durMin, 2)
        killParticipation = $kp
        objectives = @()
        deathEvents = @()
    }

    # ---- detector A: objective setup --------------------------------------
    # Anchor on the objective's own kill event rather than a hardcoded spawn
    # timer, so this stays correct across patches. The event carries the pit
    # position too, so no map constants are needed.
    foreach ($f in $frames) {
        foreach ($ev in $f.events) {
            if ($ev.type -ne 'ELITE_MONSTER_KILL') { continue }

            $ts = [long]$ev.timestamp
            $killerTeam = 0
            if ($ev.PSObject.Properties['killerTeamId'] -and $ev.killerTeamId) {
                $killerTeam = [int]$ev.killerTeamId
            }
            elseif ($ev.PSObject.Properties['killerId'] -and $teamOf.ContainsKey([int]$ev.killerId)) {
                $killerTeam = $teamOf[[int]$ev.killerId]
            }

            $anchor = $ts - ($SetupWindowSeconds * 1000)
            if ($anchor -lt 0) { $anchor = 0 }
            $fr = Get-FrameAt $frames $anchor
            $pf = Get-PF $fr $myId
            $myPos = if ($pf) { $pf.position } else { $null }

            $dist = Get-Distance $myPos $ev.position
            $stale = if ($fr) { [math]::Round(($anchor - [long]$fr.timestamp) / 1000.0, 0) } else { $null }

            $verdict = 'absent'
            if ($null -ne $dist) {
                if ($dist -le $AtPitUnits)      { $verdict = 'at pit' }
                elseif ($dist -le $NearbyUnits) { $verdict = 'arriving' }
            }

            $monster = [string]$ev.monsterType
            if ($ev.PSObject.Properties['monsterSubType'] -and $ev.monsterSubType) {
                $monster = "$monster/$($ev.monsterSubType)"
            }

            $distOut = $null
            if ($null -ne $dist) { $distOut = [int]$dist }

            $rec = [pscustomobject][ordered]@{
                matchId   = $matchId
                at        = Format-Clock $ts
                monster   = $monster
                weTookIt  = ($killerTeam -eq $myTeam)
                distanceAtMinus60 = $distOut
                verdict   = $verdict
                frameStaleSec = $stale
            }
            $game['objectives'] += $rec
            $allObj += $rec
        }
    }

    # who is the enemy jungler in this game
    $enemyJgId = 0
    foreach ($p in $match.info.participants) {
        if ([int]$p.teamId -ne $myTeam -and [string]$p.teamPosition -eq 'JUNGLE') {
            $enemyJgId = [int]$p.participantId
            break
        }
    }

    # ---- detector B: death context ---------------------------------------
    foreach ($f in $frames) {
        foreach ($ev in $f.events) {
            if ($ev.type -ne 'CHAMPION_KILL') { continue }

            # --- detector C: jungle vs jungle, BOTH directions -------------
            # Counting only your deaths answers a question nobody asked.
            $kId = 0; if ($ev.PSObject.Properties['killerId']) { $kId = [int]$ev.killerId }
            $vId = 0; if ($ev.PSObject.Properties['victimId']) { $vId = [int]$ev.victimId }

            if ($enemyJgId -gt 0 -and (($kId -eq $myId -and $vId -eq $enemyJgId) -or ($kId -eq $enemyJgId -and $vId -eq $myId))) {
                $assists = 0
                if ($ev.PSObject.Properties['assistingParticipantIds'] -and $ev.assistingParticipantIds) {
                    $assists = @($ev.assistingParticipantIds).Count
                }
                $dfr = Get-FrameAt $frames ([long]$ev.timestamp)
                $myL = $null; $mp = Get-PF $dfr $myId;      if ($mp) { $myL = [int]$mp.level }
                $ejL = $null; $ep = Get-PF $dfr $enemyJgId; if ($ep) { $ejL = [int]$ep.level }

                # championStats carries health/healthMax, so HP going INTO the
                # fight is measurable - the single biggest entry-state factor.
                # Read from the last frame before the fight, so up to 60s stale.
                $myHp = Get-HpPct $mp
                $ejHp = Get-HpPct $ep

                # Whose half did this happen in? Positive depth = enemy half,
                # which means you went there. Negative = they came to you.
                $ddp = Get-Depth $ev.position $myTeam
                $dDepth = $null
                if ($null -ne $ddp) { $dDepth = [int]$ddp }

                $allDuels += [pscustomobject][ordered]@{
                    matchId  = $matchId
                    at       = Format-Clock ([long]$ev.timestamp)
                    champion = [string]$me.championName
                    outcome  = if ($kId -eq $myId) { 'kill' } else { 'death' }
                    assists  = $assists
                    solo     = ($assists -eq 0)
                    depth    = $dDepth
                    side     = if ($null -eq $dDepth) { 'unknown' } elseif ($dDepth -gt 0) { 'enemy half' } else { 'my half' }
                    myLevel  = $myL
                    theirLevel = $ejL
                    myHpPct    = $myHp
                    theirHpPct = $ejHp
                }
            }

            if ($vId -ne $myId) { continue }

            $ts = [long]$ev.timestamp
            $fr = Get-FrameAt $frames $ts
            $myPf = Get-PF $fr $myId

            $killerId = if ($ev.PSObject.Properties['killerId']) { [int]$ev.killerId } else { 0 }
            $killerPf = if ($killerId -gt 0) { Get-PF $fr $killerId } else { $null }

            # nearest living ally, from the same (up to 60s stale) frame
            $nearestAlly = $null
            foreach ($allyId in @($teamOf.Keys)) {
                if ($allyId -eq $myId) { continue }
                if ($teamOf[$allyId] -ne $myTeam) { continue }
                $apf = Get-PF $fr $allyId
                if (-not $apf) { continue }
                $d = Get-Distance $apf.position $ev.position
                if ($null -ne $d -and ($null -eq $nearestAlly -or $d -lt $nearestAlly)) { $nearestAlly = $d }
            }

            $myLvl = $null
            if ($myPf) { $myLvl = [int]$myPf.level }
            $kLvl = $null
            if ($killerPf) { $kLvl = [int]$killerPf.level }

            $lvlDiff = $null
            if ($null -ne $myLvl -and $null -ne $kLvl) { $lvlDiff = $myLvl - $kLvl }

            $dp = Get-Depth $ev.position $myTeam
            $depthOut = $null
            if ($null -ne $dp) { $depthOut = [int]$dp }

            $allyOut = $null
            if ($null -ne $nearestAlly) { $allyOut = [int]$nearestAlly }

            $killerName = 'execution/turret'
            $killerRole = ''
            if ($killerId -gt 0) {
                $killerName = $champOf[$killerId]
                $killerRole = $roleOf[$killerId]
            }

            $staleOut = $null
            if ($fr) { $staleOut = [math]::Round(($ts - [long]$fr.timestamp) / 1000.0, 0) }

            $rec = [pscustomobject][ordered]@{
                matchId    = $matchId
                at         = Format-Clock $ts
                killer     = $killerName
                killerRole = $killerRole
                depthIntoEnemy = $depthOut
                nearestAlly = $allyOut
                myLevel     = $myLvl
                killerLevel = $kLvl
                levelDiff   = $lvlDiff
                frameStaleSec = $staleOut
            }
            $game['deathEvents'] += $rec
            $allDeaths += $rec
        }
    }

    # ---- detector D: vision spend ----------------------------------------
    # WARD_PLACED carries creatorId, timestamp and wardType but NO position,
    # so we can count and time wards but not map them. Control wards bought
    # (item 2055) is position-free and unambiguous, so it is the better metric.
    $wardsPlaced  = 0
    $controlBought = 0
    $trinketOnly  = 0
    foreach ($f in $frames) {
        foreach ($ev in $f.events) {
            if ($ev.type -eq 'WARD_PLACED' -and [int]$ev.creatorId -eq $myId) {
                $wardsPlaced++
                if ([string]$ev.wardType -match 'TRINKET') { $trinketOnly++ }
            }
            elseif ($ev.type -eq 'ITEM_PURCHASED' -and [int]$ev.participantId -eq $myId -and [int]$ev.itemId -eq 2055) {
                $controlBought++
            }
        }
    }
    $game['wardsPlaced']   = $wardsPlaced
    $game['controlWards']  = $controlBought
    $game['trinketWards']  = $trinketOnly

    # ---- detector E: invade pressure --------------------------------------
    # How much of the early game did the enemy jungler spend on YOUR side?
    $earlyFrames = 0; $enemyInMyHalf = 0
    if ($enemyJgId -gt 0) {
        foreach ($f in $frames) {
            if ([long]$f.timestamp -gt 900000) { break }   # first 15 minutes
            $epf = Get-PF $f $enemyJgId
            if (-not $epf -or -not $epf.position) { continue }
            $earlyFrames++
            $ed = Get-Depth $epf.position $myTeam
            if ($null -ne $ed -and $ed -lt 0) { $enemyInMyHalf++ }   # negative = my half
        }
    }
    $game['enemyJgInMyHalfPct'] = if ($earlyFrames -gt 0) { [math]::Round($enemyInMyHalf / $earlyFrames * 100, 0) } else { $null }

    # per-game objective setup rate, so trends can be computed later
    $objs = @($game['objectives'])
    $game['objSetupPct'] = if ($objs.Count -gt 0) {
        [math]::Round((@($objs | Where-Object { $_.verdict -ne 'absent' }).Count / $objs.Count) * 100, 0)
    } else { $null }

    # Cast to PSCustomObject so Measure-Object and Where-Object can see the
    # fields as real properties - they cannot on an OrderedDictionary.
    $games += [pscustomobject]$game
}

if ($games.Count -eq 0) {
    Write-Host "No games matched the filter. Try -JungleOnly:`$false" -ForegroundColor Yellow
    return
}

# -------------------------------------------------------------------------
# report
# -------------------------------------------------------------------------

$line = '-' * 78

Write-Host ""
Write-Host "JUNGLE REVIEW  -  $($games.Count) games" -ForegroundColor Cyan
Write-Host $line -ForegroundColor DarkGray

# State what was excluded. A sample you cannot see the edges of is not a sample.
$skippedShown = $skipped.GetEnumerator() | Where-Object { $_.Value -gt 0 } | Sort-Object Value -Descending
if ($skippedShown) {
    $parts = $skippedShown | ForEach-Object { "$($_.Value) $($_.Key)" }
    Write-Host ("  excluded: {0}" -f ($parts -join ', ')) -ForegroundColor DarkGray
}

# per game
Write-Host ""
Write-Host ("{0,-14} {1,-10} {2,-4} {3,6} {4,6} {5,6} {6,5}" -f 'MATCH','CHAMP','W/L','CS/M','VIS/M','KP%','DTHS') -ForegroundColor DarkGray
foreach ($g in $games) {
    $wl = if ($g.win) { 'W' } else { 'L' }
    $colour = if ($g.win) { 'Green' } else { 'DarkRed' }
    Write-Host ("{0,-14} {1,-10} {2,-4} {3,6} {4,6} {5,6} {6,5}" -f `
        $g.matchId.Replace('TR1_',''), $g.champion, $wl, $g.csPerMin, $g.visionPerMin, $g.killParticipation, $g.deaths) -ForegroundColor $colour
}

# aggregates vs the section 17 benchmarks
$avgCs   = [math]::Round((($games | Measure-Object csPerMin -Average).Average), 2)
$avgVis  = [math]::Round((($games | Measure-Object visionPerMin -Average).Average), 2)
$avgKp   = [math]::Round((($games | Measure-Object killParticipation -Average).Average), 0)
$avgDth  = [math]::Round((($games | Measure-Object deaths -Average).Average), 1)
$wins    = ($games | Where-Object { $_.win }).Count

Write-Host ""
Write-Host "BENCHMARKS (doctrine section 17)" -ForegroundColor Cyan
Write-Host $line -ForegroundColor DarkGray
$bench = '  {0,-20}{1,-9}{2}'
Write-Host ("  {0,-20}{1}W - {2}L" -f 'record', $wins, ($games.Count - $wins))
Write-Host ($bench -f 'cs+monsters/min', ('{0:N2}' -f $avgCs), 'gold/plat 4.5-5.5 | diamond 5.5-6.5 | master+ 6.5-8.0')
Write-Host ($bench -f 'vision/min',      ('{0:N2}' -f $avgVis), 'gold/plat 0.6-0.9 | diamond 0.9-1.2 | master+ 1.1-1.5')
Write-Host ($bench -f 'kill participation', ("$avgKp%"),        'gold/plat 45-55%  | diamond 55-65%  | master+ 60-75%')
Write-Host ($bench -f 'deaths/game',     ('{0:N1}' -f $avgDth), 'gold/plat 6-8     | diamond 4-6     | master+ 3-5')

# objective setup - the M2 headline
$objTotal = $allObj.Count
if ($objTotal -gt 0) {
    $atPit    = ($allObj | Where-Object { $_.verdict -eq 'at pit' }).Count
    $arriving = ($allObj | Where-Object { $_.verdict -eq 'arriving' }).Count
    $absent   = ($allObj | Where-Object { $_.verdict -eq 'absent' }).Count
    $setupRate = [math]::Round((($atPit + $arriving) / $objTotal) * 100, 0)

    Write-Host ""
    Write-Host "OBJECTIVE SETUP (doctrine section 09)" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkGray
    Write-Host "  Where you were 60 seconds before each objective died."
    Write-Host ""
    Write-Host ("  at pit     {0,4}  ({1}%)" -f $atPit,    [math]::Round($atPit/$objTotal*100,0)) -ForegroundColor Green
    Write-Host ("  arriving   {0,4}  ({1}%)" -f $arriving, [math]::Round($arriving/$objTotal*100,0)) -ForegroundColor Yellow
    Write-Host ("  absent     {0,4}  ({1}%)" -f $absent,   [math]::Round($absent/$objTotal*100,0)) -ForegroundColor Red
    Write-Host ""
    Write-Host ("  SETUP RATE: {0}%  of {1} objectives" -f $setupRate, $objTotal) -ForegroundColor Cyan

    $ours   = $allObj | Where-Object { $_.weTookIt }
    $theirs = $allObj | Where-Object { -not $_.weTookIt }
    if ($theirs.Count -gt 0) {
        $absentOnTheirs = ($theirs | Where-Object { $_.verdict -eq 'absent' }).Count
        Write-Host ("  On objectives the ENEMY took, you were absent {0} of {1} times ({2}%)." -f `
            $absentOnTheirs, $theirs.Count, [math]::Round($absentOnTheirs/$theirs.Count*100,0)) -ForegroundColor DarkYellow
    }
    if ($ours.Count -gt 0) {
        Write-Host ("  Your team took {0} of {1} objectives." -f $ours.Count, $objTotal) -ForegroundColor DarkGray
    }
}

# deaths - the 1v1 question
if ($allDeaths.Count -gt 0) {
    $jgDeaths = $allDeaths | Where-Object { $_.killerRole -eq 'JUNGLE' }

    Write-Host ""
    Write-Host "DEATHS  -  $($allDeaths.Count) total, $($jgDeaths.Count) to the enemy jungler" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkGray

    if ($jgDeaths.Count -gt 0) {
        $withLvl = $jgDeaths | Where-Object { $null -ne $_.levelDiff }
        if ($withLvl.Count -gt 0) {
            $behind = ($withLvl | Where-Object { $_.levelDiff -lt 0 }).Count
            $even   = ($withLvl | Where-Object { $_.levelDiff -eq 0 }).Count
            $ahead  = ($withLvl | Where-Object { $_.levelDiff -gt 0 }).Count
            Write-Host "  Level state when the enemy jungler killed you:"
            Write-Host ("    a level or more BEHIND  {0,3}  ({1}%)" -f $behind, [math]::Round($behind/$withLvl.Count*100,0)) -ForegroundColor Red
            Write-Host ("    even                    {0,3}  ({1}%)" -f $even,   [math]::Round($even/$withLvl.Count*100,0)) -ForegroundColor Yellow
            Write-Host ("    AHEAD                   {0,3}  ({1}%)" -f $ahead,  [math]::Round($ahead/$withLvl.Count*100,0)) -ForegroundColor Green
            Write-Host ""
            Write-Host "  If most sit in the first two rows, you are losing duels on entry state," -ForegroundColor DarkGray
            Write-Host "  not on mechanics. That is a pathing fix, not an aim fix." -ForegroundColor DarkGray
        }

        $deep = $jgDeaths | Where-Object { $null -ne $_.depthIntoEnemy -and $_.depthIntoEnemy -gt 0 }
        Write-Host ""
        Write-Host ("  {0} of {1} were inside the enemy half of the map." -f $deep.Count, $jgDeaths.Count)
        $isolated = $jgDeaths | Where-Object { $null -ne $_.nearestAlly -and $_.nearestAlly -gt 4000 }
        Write-Host ("  {0} of {1} had no ally within 4000 units (frame up to 60s stale)." -f $isolated.Count, $jgDeaths.Count)

        Write-Host ""
        Write-Host "  Worst five (deepest, alone):" -ForegroundColor DarkGray
        $jgDeaths |
            Where-Object { $null -ne $_.depthIntoEnemy } |
            Sort-Object -Property @{E={$_.depthIntoEnemy}} -Descending |
            Select-Object -First 5 |
            ForEach-Object {
                Write-Host ("    {0}  {1,-5}  killed by {2,-12} depth {3,6}  nearest ally {4,6}  lvl {5} v {6}" -f `
                    $_.matchId.Replace('TR1_',''), $_.at, $_.killer, $_.depthIntoEnemy, $_.nearestAlly, $_.myLevel, $_.killerLevel)
            }
    }
}

# jungle vs jungle, both directions
if ($allDuels.Count -gt 0) {
    $k = ($allDuels | Where-Object { $_.outcome -eq 'kill' }).Count
    $d = ($allDuels | Where-Object { $_.outcome -eq 'death' }).Count

    Write-Host ""
    Write-Host "YOU vs THE ENEMY JUNGLER  -  every interaction, both directions" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkGray
    Write-Host ("  You killed them {0} times. They killed you {1} times." -f $k, $d)
    $pct = [math]::Round($k / [math]::Max($k + $d, 1) * 100, 0)
    Write-Host ("  You win {0}% of jungle-vs-jungle kill exchanges." -f $pct) -ForegroundColor $(if ($pct -ge 45) { 'Green' } else { 'Yellow' })

    # a real 1v1 = the killer had nobody assisting
    $solo = $allDuels | Where-Object { $_.solo }
    if ($solo.Count -gt 0) {
        $sk = ($solo | Where-Object { $_.outcome -eq 'kill' }).Count
        $sd = ($solo | Where-Object { $_.outcome -eq 'death' }).Count
        $spct = [math]::Round($sk / [math]::Max($sk + $sd, 1) * 100, 0)
        Write-Host ""
        Write-Host ("  Clean 1v1s only (no assists on the killing side): {0} of {1}" -f $solo.Count, $allDuels.Count) -ForegroundColor DarkGray
        Write-Host ("    you {0} - {1} them   =  {2}% solo duel win rate" -f $sk, $sd, $spct) -ForegroundColor $(if ($spct -ge 45) { 'Green' } else { 'Yellow' })
    }

    $assisted = $allDuels | Where-Object { -not $_.solo }
    if ($assisted.Count -gt 0) {
        $ak = ($assisted | Where-Object { $_.outcome -eq 'kill' }).Count
        $ad = ($assisted | Where-Object { $_.outcome -eq 'death' }).Count
        Write-Host ("  With help on either side: you {0} - {1} them" -f $ak, $ad) -ForegroundColor DarkGray
    }

    # HP going into the fight - the entry-state test
    $hpKnown = $allDuels | Where-Object { $null -ne $_.myHpPct -and $null -ne $_.theirHpPct }
    if ($hpKnown.Count -gt 0) {
        $lost = @($hpKnown | Where-Object { $_.outcome -eq 'death' })
        $won  = @($hpKnown | Where-Object { $_.outcome -eq 'kill' })
        Write-Host ""
        Write-Host "  HP entering the fight (last frame before it, up to 60s stale):" -ForegroundColor Cyan
        if ($lost.Count) {
            Write-Host ("    fights you LOST: you {0}%  them {1}%" -f `
                [int](($lost | Measure-Object myHpPct -Average).Average),
                [int](($lost | Measure-Object theirHpPct -Average).Average)) -ForegroundColor Red
        }
        if ($won.Count) {
            Write-Host ("    fights you WON:  you {0}%  them {1}%" -f `
                [int](($won | Measure-Object myHpPct -Average).Average),
                [int](($won | Measure-Object theirHpPct -Average).Average)) -ForegroundColor Green
        }
    }

    # WHOSE half did these happen in? Tests "they invade me" directly.
    $known = $allDuels | Where-Object { $_.side -ne 'unknown' }
    if ($known.Count -gt 0) {
        $mine  = @($known | Where-Object { $_.side -eq 'my half' })
        $their = @($known | Where-Object { $_.side -eq 'enemy half' })
        Write-Host ""
        Write-Host "  WHERE these fights happened:" -ForegroundColor Cyan
        Write-Host ("    your half   {0,3}  ({1}%)   you {2}-{3}" -f $mine.Count,
            [math]::Round($mine.Count/$known.Count*100,0),
            @($mine  | Where-Object { $_.outcome -eq 'kill' }).Count,
            @($mine  | Where-Object { $_.outcome -eq 'death' }).Count)
        Write-Host ("    their half  {0,3}  ({1}%)   you {2}-{3}" -f $their.Count,
            [math]::Round($their.Count/$known.Count*100,0),
            @($their | Where-Object { $_.outcome -eq 'kill' }).Count,
            @($their | Where-Object { $_.outcome -eq 'death' }).Count)

        Write-Host ""
        Write-Host "  By champion (fights in YOUR half = you were invaded):" -ForegroundColor Cyan
        $known | Group-Object champion | Sort-Object Count -Descending | ForEach-Object {
            $g = $_.Group
            $inMine = @($g | Where-Object { $_.side -eq 'my half' }).Count
            $kk = @($g | Where-Object { $_.outcome -eq 'kill' }).Count
            $dd = @($g | Where-Object { $_.outcome -eq 'death' }).Count
            Write-Host ("    {0,-10} {1,3} fights   {2,3} in your half ({3,3}%)   record {4}-{5}" -f `
                $_.Name, $g.Count, $inMine, [math]::Round($inMine/$g.Count*100,0), $kk, $dd)
        }
    }
}

# vision spend - doctrine section 10
$avgWards   = [math]::Round((($games | Measure-Object wardsPlaced -Average).Average), 1)
$avgControl = [math]::Round((($games | Measure-Object controlWards -Average).Average), 1)
$noControl  = @($games | Where-Object { $_.controlWards -eq 0 }).Count
Write-Host ""
Write-Host "VISION SPEND (doctrine section 10)" -ForegroundColor Cyan
Write-Host $line -ForegroundColor DarkGray
Write-Host ("  wards placed/game    {0}" -f $avgWards)
Write-Host ("  control wards/game   {0}" -f $avgControl) -ForegroundColor $(if ($avgControl -ge 3) { 'Green' } else { 'Red' })
Write-Host ("  games with ZERO control wards bought: {0} of {1}" -f $noControl, $games.Count) -ForegroundColor $(if ($noControl -eq 0) { 'Green' } else { 'Red' })
Write-Host "  A control ward is 75 gold. One per back is the doctrine rule." -ForegroundColor DarkGray

# invade pressure - how much do they live in your jungle
$invaded = $games | Where-Object { $null -ne $_.enemyJgInMyHalfPct }
if ($invaded.Count -gt 0) {
    $avgInv = [math]::Round((($invaded | Measure-Object enemyJgInMyHalfPct -Average).Average), 0)
    Write-Host ""
    Write-Host "INVADE PRESSURE  -  first 15 minutes" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkGray
    Write-Host ("  The enemy jungler was in YOUR half {0}% of sampled early minutes." -f $avgInv)
    $worst = $invaded | Sort-Object enemyJgInMyHalfPct -Descending | Select-Object -First 3
    foreach ($w in $worst) {
        Write-Host ("    {0}  {1,-9} {2,3}%" -f $w.matchId.Replace('TR1_',''), $w.champion, $w.enemyJgInMyHalfPct) -ForegroundColor DarkGray
    }
    Write-Host "  Above ~35% means they are living in your jungle and dictating the game." -ForegroundColor DarkGray
}

# per champion - doctrine section 13 says small pools climb
Write-Host ""
Write-Host "CHAMPION POOL (doctrine section 13)" -ForegroundColor Cyan
Write-Host $line -ForegroundColor DarkGray
$games | Group-Object champion | Sort-Object Count -Descending | ForEach-Object {
    $w = ($_.Group | Where-Object { $_.win }).Count
    $l = $_.Count - $w
    $d = [math]::Round((($_.Group | Measure-Object deaths -Average).Average), 1)
    $c = [math]::Round((($_.Group | Measure-Object csPerMin -Average).Average), 2)
    Write-Host ("  {0,-12} {1,2} games   {2}W-{3}L   {4,4} deaths/game   {5,5} cs/min" -f $_.Name, $_.Count, $w, $l, $d, $c)
}
Write-Host ("  {0} champions across {1} games." -f ($games | Group-Object champion).Count, $games.Count) -ForegroundColor DarkYellow

# sessions and loss streaks - doctrine section 14
$timed = $games | Where-Object { $_.startMs -gt 0 } | Sort-Object startMs
if ($timed.Count -gt 1) {
    Write-Host ""
    Write-Host "QUEUE DISCIPLINE (doctrine section 14)" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkGray

    $sessions = @()
    $current  = @()
    $prevMs   = 0
    foreach ($g in $timed) {
        if ($prevMs -gt 0 -and ($g.startMs - $prevMs) -gt (3 * 3600 * 1000)) {
            $sessions += ,$current
            $current = @()
        }
        $current += $g
        $prevMs = $g.startMs
    }
    if ($current.Count) { $sessions += ,$current }

    $tiltGames = 0; $tiltWins = 0
    foreach ($s in $sessions) {
        $streak = 0
        foreach ($g in $s) {
            if ($streak -ge 2) {
                $tiltGames++
                if ($g.win) { $tiltWins++ }
            }
            if ($g.win) { $streak = 0 } else { $streak++ }
        }
        $seq = ($s | ForEach-Object { if ($_.win) { 'W' } else { 'L' } }) -join ''
        Write-Host ("  {0}  {1,2} games   {2}" -f $s[0].startedUtc, $s.Count, $seq)
    }
    Write-Host ""
    if ($tiltGames -gt 0) {
        $rate = [math]::Round($tiltWins / $tiltGames * 100, 0)
        Write-Host ("  You queued {0} games while already on a 2+ loss streak, and won {1} ({2}%)." -f $tiltGames, $tiltWins, $rate) -ForegroundColor Red
        Write-Host "  The section 14 rule says stop at two. This is what ignoring it costs." -ForegroundColor DarkGray
    } else {
        Write-Host "  You never queued on a 2+ loss streak. The stopping rule is being followed." -ForegroundColor Green
    }
}

# trend - is anything you changed actually working?
$timedAll = @($games | Where-Object { $_.startMs -gt 0 } | Sort-Object startMs)
if ($timedAll.Count -ge 6) {
    $half  = [int]([math]::Floor($timedAll.Count / 2))
    $older = $timedAll[0..($half - 1)]
    $newer = $timedAll[$half..($timedAll.Count - 1)]

    Write-Host ""
    Write-Host "TREND  -  older half vs newer half" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkGray
    Write-Host ("  {0,-22} {1,8} {2,8}" -f '', 'OLDER', 'NEWER') -ForegroundColor DarkGray

    foreach ($m in @(
        @{ label='cs+monsters/min';    prop='csPerMin';          dp=2; up=$true  }
        @{ label='vision/min';         prop='visionPerMin';      dp=2; up=$true  }
        @{ label='control wards';      prop='controlWards';      dp=1; up=$true  }
        @{ label='kill participation'; prop='killParticipation'; dp=0; up=$true  }
        @{ label='deaths';             prop='deaths';            dp=1; up=$false }
        @{ label='objective setup %';  prop='objSetupPct';       dp=0; up=$true  }
    )) {
        Show-Trend -Older $older -Newer $newer -Label $m.label -Prop $m.prop -Decimals $m.dp -HigherIsBetter $m.up
    }

    $ow = @($older | Where-Object { $_.win }).Count
    $nw = @($newer | Where-Object { $_.win }).Count
    Write-Host ("  {0,-22} {1,8} {2,8}" -f 'record', "$ow-$($older.Count-$ow)", "$nw-$($newer.Count-$nw)")
    Write-Host "  Re-run after 20 more games. This is the row that tells you if a fix worked." -ForegroundColor DarkGray
}

# optional markdown report - for pasting into a chat, an issue, or a log
if ($MarkdownOut) {
    $md = [System.Collections.Generic.List[string]]::new()
    $md.Add("# Jungle review - $($games.Count) games")
    $md.Add("")
    $md.Add("Generated $((Get-Date).ToString('yyyy-MM-dd HH:mm')). Record: ${wins}W-$($games.Count - $wins)L.")
    $md.Add("")
    $md.Add("## Benchmarks")
    $md.Add("")
    $md.Add("| metric | you | gold/plat | diamond | master+ |")
    $md.Add("|---|---|---|---|---|")
    $md.Add("| cs+monsters/min | $('{0:N2}' -f $avgCs) | 4.5-5.5 | 5.5-6.5 | 6.5-8.0 |")
    $md.Add("| vision/min | $('{0:N2}' -f $avgVis) | 0.6-0.9 | 0.9-1.2 | 1.1-1.5 |")
    $md.Add("| kill participation | $avgKp% | 45-55% | 55-65% | 60-75% |")
    $md.Add("| deaths/game | $('{0:N1}' -f $avgDth) | 6-8 | 4-6 | 3-5 |")
    $md.Add("")
    if ($objTotal -gt 0) {
        $md.Add("## Objective setup")
        $md.Add("")
        $md.Add("Setup rate **$setupRate%** across $objTotal objectives (at pit $atPit, arriving $arriving, absent $absent).")
        $md.Add("")
    }
    if ($allDuels.Count -gt 0) {
        $dk = @($allDuels | Where-Object { $_.outcome -eq 'kill' }).Count
        $dd = @($allDuels | Where-Object { $_.outcome -eq 'death' }).Count
        $md.Add("## You vs the enemy jungler")
        $md.Add("")
        $md.Add("$dk kills, $dd deaths across $($allDuels.Count) exchanges.")
        $md.Add("")
    }
    $md.Add("## Games")
    $md.Add("")
    $md.Add("| match | champion | result | cs/min | vision/min | kp | deaths |")
    $md.Add("|---|---|---|---|---|---|---|")
    foreach ($g in $games) {
        $md.Add("| $($g.matchId) | $($g.champion) | $(if ($g.win) { 'W' } else { 'L' }) | $($g.csPerMin) | $($g.visionPerMin) | $($g.killParticipation)% | $($g.deaths) |")
    }
    $md.Add("")
    $md.Add("_Position frames sample once per minute, so frame-derived values can be up to 60s stale. No minion data exists in the API, so wave state is never measured._")
    Set-Content -Path $MarkdownOut -Value ($md -join "`n") -Encoding UTF8
    Write-Host "markdown report written to $MarkdownOut" -ForegroundColor DarkGray
}

# facts file for the later LLM pass (milestone M4)
$factsFile = Join-Path $DataDir 'facts.json'
@{
    generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    gameCount    = $games.Count
    aggregates   = @{
        csPerMin = $avgCs; visionPerMin = $avgVis
        killParticipation = $avgKp; deathsPerGame = $avgDth
        wins = $wins; losses = ($games.Count - $wins)
        objectiveSetupRatePct = if ($objTotal -gt 0) { $setupRate } else { $null }
    }
    games = $games
} | ConvertTo-Json -Depth 30 | Set-Content $factsFile -Encoding UTF8

Write-Host ""
Write-Host $line -ForegroundColor DarkGray
Write-Host "facts written to $factsFile" -ForegroundColor DarkGray
Write-Host "That file is the input for the LLM pass - paste it to me and I will review it." -ForegroundColor DarkGray
Write-Host ""
