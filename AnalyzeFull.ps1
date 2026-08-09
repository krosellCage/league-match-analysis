# AnalyzeFull.ps1 - wide-spectrum analysis across every queue.
#
# Where AnalyzeLane.ps1 answers "how is my lane going", this answers
# "where do my games actually get decided". The centrepiece is conversion:
# win rate GIVEN a lead, which separates winning your lane from winning games.
#
#   .\AnalyzeFull.ps1 -DataDir .\data-umut-all -JsonOut full.json

param(
    [string]$DataDir = "$PSScriptRoot\data",
    [double]$MinDurationMinutes = 8,
    [int]$UtcOffsetHours = 3,          # TR local time
    [int]$SoloDeathUnits = 4000,       # no ally this close = died alone
    [string]$JsonOut
)

$ErrorActionPreference = 'Stop'

$QueueNames = @{
    400='Normal Draft'; 420='Dereceli Tekli'; 430='Normal Kör'; 440='Dereceli Esnek'
    450='ARAM'; 490='Hızlı Oyun'; 700='Clash'; 720='ARAM Clash'
    830='Co-op Giriş'; 840='Co-op Orta'; 850='Co-op Zor'
    # Verified against the cached matches: 1700/1710/1740/1750 are all map 30
    # (CHERRY), i.e. Arena variants, so they are grouped under one name.
    1700='Arena'; 1710='Arena'; 1740='Arena'; 1750='Arena'
    710='Diğer (Rift)'; 1900='URF'; 900='URF'
}
$MapNames = @{ 11='Summoner''s Rift'; 12='Howling Abyss'; 21='Nexus Blitz'; 30='Arena' }

function Get-FrameAt($frames, [long]$ms) {
    $best = $null
    foreach ($f in $frames) { if ([long]$f.timestamp -le $ms) { $best = $f } else { break } }
    if (-not $best -and $frames.Count -gt 0) { $best = $frames[0] }
    return $best
}
function Get-PF($frame, [int]$participantId) {
    if (-not $frame) { return $null }
    return $frame.participantFrames."$participantId"
}
function Get-Dist($a, $b) {
    if (-not $a -or -not $b) { return $null }
    $dx = [double]$a.x - [double]$b.x; $dy = [double]$a.y - [double]$b.y
    return [math]::Sqrt($dx*$dx + $dy*$dy)
}
function Avg($set, $prop) {
    $v = @($set | Where-Object { $null -ne $_.$prop } | ForEach-Object { $_.$prop })
    if ($v.Count -eq 0) { return $null }
    return ($v | Measure-Object -Average).Average
}
function Rate($set) {
    $s = @($set)
    if ($s.Count -eq 0) { return $null }
    return [math]::Round((@($s | Where-Object { $_.win }).Count / $s.Count) * 100, 0)
}

$acct  = Get-Content (Join-Path $DataDir 'account.json') -Raw | ConvertFrom-Json
$puuid = $acct.puuid
$matchDir = Join-Path $DataDir 'matches'; $timelineDir = Join-Path $DataDir 'timelines'

$games = @(); $skipRemake = 0; $skipNoTl = 0
$deathBuckets = @{}   # 5-minute buckets across all games

foreach ($mf in (Get-ChildItem $matchDir -Filter *.json | Sort-Object Name)) {
    $id = $mf.BaseName
    $tf = Join-Path $timelineDir "$id.json"
    if (-not (Test-Path $tf)) { $skipNoTl++; continue }

    $match = Get-Content $mf.FullName -Raw | ConvertFrom-Json
    $me = $match.info.participants | Where-Object { $_.puuid -eq $puuid }
    if (-not $me) { $skipNoTl++; continue }

    $dur = [double]$match.info.gameDuration
    if ($dur -gt 100000) { $dur = $dur / 1000.0 }
    if ($dur -lt ($MinDurationMinutes * 60)) { $skipRemake++; continue }
    $durMin = [math]::Max($dur / 60.0, 1.0)

    $timeline = Get-Content $tf -Raw | ConvertFrom-Json
    $frames = $timeline.info.frames

    $qid   = [int]$match.info.queueId
    $mapId = [int]$match.info.mapId
    $queue = if ($QueueNames.ContainsKey($qid)) { $QueueNames[$qid] } else { "Kuyruk $qid" }
    $map   = if ($MapNames.ContainsKey($mapId)) { $MapNames[$mapId] } else { "Harita $mapId" }

    $myId = [int]$me.participantId; $myTeam = [int]$me.teamId
    $role = [string]$me.teamPosition; if ([string]::IsNullOrWhiteSpace($role)) { $role = 'YOK' }

    $opp = $match.info.participants |
        Where-Object { [int]$_.teamId -ne $myTeam -and [string]$_.teamPosition -eq $role -and $role -ne 'YOK' } |
        Select-Object -First 1

    # --- lane and team differentials at the standard checkpoints ---
    $d = @{}
    foreach ($mk in @(5,10,15)) {
        $fr = Get-FrameAt $frames ($mk*60*1000)
        $ok = $fr -and ([long]$fr.timestamp -ge (($mk-1)*60*1000))
        $mp = Get-PF $fr $myId
        $op = if ($opp) { Get-PF $fr ([int]$opp.participantId) } else { $null }
        if ($ok -and $mp -and $op) {
            $d["gold$mk"] = [int]$mp.totalGold - [int]$op.totalGold
            $d["cs$mk"]   = ([int]$mp.minionsKilled + [int]$mp.jungleMinionsKilled) - ([int]$op.minionsKilled + [int]$op.jungleMinionsKilled)
            $d["xp$mk"]   = [int]$mp.xp - [int]$op.xp
        } else { $d["gold$mk"]=$null; $d["cs$mk"]=$null; $d["xp$mk"]=$null }

        # whole-team gold difference: separates "my lane won" from "we're winning"
        if ($ok -and $fr) {
            $mine = 0; $theirs = 0; $any = $false
            foreach ($p in $match.info.participants) {
                $pf = Get-PF $fr ([int]$p.participantId)
                if (-not $pf) { continue }
                $any = $true
                if ([int]$p.teamId -eq $myTeam) { $mine += [int]$pf.totalGold } else { $theirs += [int]$pf.totalGold }
            }
            $d["team$mk"] = if ($any) { $mine - $theirs } else { $null }
        } else { $d["team$mk"] = $null }
    }

    # --- deaths: when, and whether alone ---
    $myDeaths = 0; $soloDeaths = 0; $earlyDeaths = 0; $firstDeath = $null
    foreach ($f in $frames) {
        foreach ($ev in $f.events) {
            if ($ev.type -ne 'CHAMPION_KILL') { continue }
            if ([int]$ev.victimId -ne $myId) { continue }
            $ts = [long]$ev.timestamp
            $myDeaths++
            if ($null -eq $firstDeath) { $firstDeath = $ts }
            if ($ts -le 900000) { $earlyDeaths++ }

            $b = [int][math]::Floor($ts / 300000)      # 5-minute bucket
            if (-not $deathBuckets.ContainsKey($b)) { $deathBuckets[$b] = 0 }
            $deathBuckets[$b]++

            $dfr = Get-FrameAt $frames $ts
            $near = $null
            foreach ($p in $match.info.participants) {
                if ([int]$p.participantId -eq $myId -or [int]$p.teamId -ne $myTeam) { continue }
                $apf = Get-PF $dfr ([int]$p.participantId)
                if (-not $apf) { continue }
                $dd = Get-Dist $apf.position $ev.position
                if ($null -ne $dd -and ($null -eq $near -or $dd -lt $near)) { $near = $dd }
            }
            if ($null -ne $near -and $near -gt $SoloDeathUnits) { $soloDeaths++ }
        }
    }

    $teamKills = 0; $teamDmg = 0; $teamGold = 0
    foreach ($p in $match.info.participants) {
        if ([int]$p.teamId -eq $myTeam) {
            $teamKills += [int]$p.kills
            $teamDmg   += [int]$p.totalDamageDealtToChampions
            $teamGold  += [int]$p.goldEarned
        }
    }

    $cs   = [int]$me.totalMinionsKilled + [int]$me.neutralMinionsKilled
    $gold = [int]$me.goldEarned
    $dmg  = [int]$me.totalDamageDealtToChampions
    $startMs = 0
    if ($match.info.PSObject.Properties['gameStartTimestamp']) { $startMs = [long]$match.info.gameStartTimestamp }
    $local = if ($startMs -gt 0) { [DateTimeOffset]::FromUnixTimeMilliseconds($startMs).UtcDateTime.AddHours($UtcOffsetHours) } else { $null }

    $games += [pscustomobject][ordered]@{
        matchId = $id; startMs = $startMs
        date    = if ($local) { $local.ToString('yyyy-MM-dd') } else { '' }
        hour    = if ($local) { $local.Hour } else { $null }
        queueId = $qid; queue = $queue; mapId = $mapId; map = $map
        role = $role; champion = [string]$me.championName
        opponent = if ($opp) { [string]$opp.championName } else { '' }
        win = [bool]$me.win; side = $(if ($myTeam -eq 100) { 'Mavi' } else { 'Kırmızı' })
        durationMin = [math]::Round($durMin,1)
        kills=[int]$me.kills; deaths=[int]$me.deaths; assists=[int]$me.assists
        csPerMin     = [math]::Round($cs/$durMin,2)
        goldPerMin   = [int]($gold/$durMin)
        visionPerMin = [math]::Round([double]$me.visionScore/$durMin,2)
        dmgPerMin    = [int]($dmg/$durMin)
        dmgShare     = if ($teamDmg -gt 0) { [math]::Round($dmg/$teamDmg*100,0) } else { $null }
        goldShare    = if ($teamGold -gt 0) { [math]::Round($gold/$teamGold*100,0) } else { $null }
        dmgPerKGold  = if ($gold -gt 0) { [int]($dmg / ($gold/1000.0)) } else { $null }
        killParticipation = if ($teamKills -gt 0) { [math]::Round((([int]$me.kills+[int]$me.assists)/$teamKills)*100,0) } else { $null }
        deathsTimeline = $myDeaths
        soloDeaths   = $soloDeaths
        earlyDeaths  = $earlyDeaths
        firstDeathMin = if ($null -ne $firstDeath) { [math]::Round($firstDeath/60000.0,1) } else { $null }
        goldDiff5=$d['gold5']; goldDiff10=$d['gold10']; goldDiff15=$d['gold15']
        csDiff10=$d['cs10']; csDiff15=$d['cs15']; xpDiff10=$d['xp10']
        teamDiff10=$d['team10']; teamDiff15=$d['team15']
    }
}

if ($games.Count -eq 0) { throw "No usable games in $DataDir" }

$sr    = @($games | Where-Object { $_.mapId -eq 11 })          # Summoner's Rift only
$laned = @($sr | Where-Object { $_.role -ne 'YOK' })
$sorted = @($games | Sort-Object startMs)

$out = [ordered]@{
    account = "$($acct.gameName)#$($acct.tagLine)"
    generated = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    totalGames = $games.Count; remakesExcluded = $skipRemake; unusable = $skipNoTl
    firstDate = $sorted[0].date; lastDate = $sorted[-1].date
    overallWinRate = (Rate $games)
    riftGames = $sr.Count; lanedGames = $laned.Count
}

# by queue / map / role / side / champion
$out.byQueue = @($games | Group-Object queue | Sort-Object Count -Descending | ForEach-Object {
    @{ name=$_.Name; games=$_.Count; wins=@($_.Group|Where-Object win).Count; winRate=(Rate $_.Group)
       deaths=[math]::Round((Avg $_.Group 'deaths'),1); kp=[math]::Round((Avg $_.Group 'killParticipation'),0) } })

$out.byRole = @($laned | Group-Object role | Sort-Object Count -Descending | ForEach-Object {
    @{ name=$_.Name; games=$_.Count; winRate=(Rate $_.Group)
       csPerMin=[math]::Round((Avg $_.Group 'csPerMin'),2)
       goldDiff10=[int](Avg $_.Group 'goldDiff10'); goldDiff15=[int](Avg $_.Group 'goldDiff15')
       deaths=[math]::Round((Avg $_.Group 'deaths'),1)
       kp=[math]::Round((Avg $_.Group 'killParticipation'),0)
       dmgShare=[math]::Round((Avg $_.Group 'dmgShare'),0) } })

$out.bySide = @($sr | Group-Object side | ForEach-Object {
    @{ name=$_.Name; games=$_.Count; winRate=(Rate $_.Group) } })

$out.byChampion = @($sr | Group-Object champion | Where-Object { $_.Count -ge 3 } |
    Sort-Object Count -Descending | Select-Object -First 16 | ForEach-Object {
    @{ name=$_.Name; games=$_.Count; wins=@($_.Group|Where-Object win).Count; winRate=(Rate $_.Group)
       csPerMin=[math]::Round((Avg $_.Group 'csPerMin'),2)
       goldDiff10=[int](Avg $_.Group 'goldDiff10')
       deaths=[math]::Round((Avg $_.Group 'deaths'),1)
       dmgShare=[math]::Round((Avg $_.Group 'dmgShare'),0) } })

# THE conversion metric: win rate given a lead
$withTeam15 = @($sr | Where-Object { $null -ne $_.teamDiff15 })
$out.conversion = @{
    teamAhead15   = @{ games=@($withTeam15|Where-Object{$_.teamDiff15 -gt 1500}).Count; winRate=(Rate ($withTeam15|Where-Object{$_.teamDiff15 -gt 1500})) }
    teamEven15    = @{ games=@($withTeam15|Where-Object{$_.teamDiff15 -ge -1500 -and $_.teamDiff15 -le 1500}).Count; winRate=(Rate ($withTeam15|Where-Object{$_.teamDiff15 -ge -1500 -and $_.teamDiff15 -le 1500})) }
    teamBehind15  = @{ games=@($withTeam15|Where-Object{$_.teamDiff15 -lt -1500}).Count; winRate=(Rate ($withTeam15|Where-Object{$_.teamDiff15 -lt -1500})) }
}
$withLane15 = @($laned | Where-Object { $null -ne $_.goldDiff15 })
$out.conversion.laneAhead15  = @{ games=@($withLane15|Where-Object{$_.goldDiff15 -gt 500}).Count; winRate=(Rate ($withLane15|Where-Object{$_.goldDiff15 -gt 500})) }
$out.conversion.laneBehind15 = @{ games=@($withLane15|Where-Object{$_.goldDiff15 -lt -500}).Count; winRate=(Rate ($withLane15|Where-Object{$_.goldDiff15 -lt -500})) }

# game length
$out.byLength = @(
    @{ name='0-25 dk';  games=@($sr|Where-Object{$_.durationMin -lt 25}).Count; winRate=(Rate ($sr|Where-Object{$_.durationMin -lt 25})) }
    @{ name='25-32 dk'; games=@($sr|Where-Object{$_.durationMin -ge 25 -and $_.durationMin -lt 32}).Count; winRate=(Rate ($sr|Where-Object{$_.durationMin -ge 25 -and $_.durationMin -lt 32})) }
    @{ name='32+ dk';   games=@($sr|Where-Object{$_.durationMin -ge 32}).Count; winRate=(Rate ($sr|Where-Object{$_.durationMin -ge 32})) }
)

# averages
$out.averages = @{
    csPerMin=[math]::Round((Avg $laned 'csPerMin'),2); goldPerMin=[int](Avg $laned 'goldPerMin')
    visionPerMin=[math]::Round((Avg $sr 'visionPerMin'),2)
    kp=[math]::Round((Avg $sr 'killParticipation'),0)
    deaths=[math]::Round((Avg $sr 'deaths'),1)
    earlyDeaths=[math]::Round((Avg $sr 'earlyDeaths'),2)
    soloDeaths=[math]::Round((Avg $sr 'soloDeaths'),2)
    firstDeathMin=[math]::Round((Avg $sr 'firstDeathMin'),1)
    dmgPerMin=[int](Avg $sr 'dmgPerMin'); dmgShare=[math]::Round((Avg $sr 'dmgShare'),0)
    goldShare=[math]::Round((Avg $sr 'goldShare'),0); dmgPerKGold=[int](Avg $sr 'dmgPerKGold')
    goldDiff5=[int](Avg $laned 'goldDiff5'); goldDiff10=[int](Avg $laned 'goldDiff10'); goldDiff15=[int](Avg $laned 'goldDiff15')
    csDiff10=[math]::Round((Avg $laned 'csDiff10'),1); csDiff15=[math]::Round((Avg $laned 'csDiff15'),1)
}
$totalDeaths = ($sr | Measure-Object deathsTimeline -Sum).Sum
$totalSolo   = ($sr | Measure-Object soloDeaths -Sum).Sum
$out.soloDeathPct = if ($totalDeaths -gt 0) { [math]::Round($totalSolo/$totalDeaths*100,0) } else { $null }

# deaths across the clock
$out.deathClock = @($deathBuckets.GetEnumerator() | Sort-Object Name | Where-Object { $_.Name -le 11 } | ForEach-Object {
    @{ from=[int]$_.Name*5; to=([int]$_.Name*5+5); deaths=$_.Value } })

# time of day
$out.byHour = @($sr | Where-Object { $null -ne $_.hour } | Group-Object { [int][math]::Floor($_.hour/4)*4 } |
    Sort-Object { [int]$_.Name } | ForEach-Object {
    @{ band=("{0:d2}:00-{1:d2}:00" -f [int]$_.Name, ([int]$_.Name+4)); games=$_.Count; winRate=(Rate $_.Group)
       deaths=[math]::Round((Avg $_.Group 'deaths'),1) } })

# trend
$srSorted = @($sr | Sort-Object startMs)
if ($srSorted.Count -ge 10) {
    $h = [int][math]::Floor($srSorted.Count/2)
    $o = $srSorted[0..($h-1)]; $n = $srSorted[$h..($srSorted.Count-1)]
    $out.trend = @{}
    foreach ($p in @('csPerMin','visionPerMin','killParticipation','deaths','earlyDeaths','soloDeaths','goldDiff10','dmgShare')) {
        $out.trend[$p] = @{ older=[math]::Round((Avg $o $p),2); newer=[math]::Round((Avg $n $p),2) }
    }
    $out.trend['winRate'] = @{ older=(Rate $o); newer=(Rate $n) }
}

if ($JsonOut) { $out | ConvertTo-Json -Depth 12 | Set-Content $JsonOut -Encoding UTF8; Write-Host "written to $JsonOut" -ForegroundColor Green }

# --- console ---
"HESAP        $($out.account)"
"MACLAR       $($out.totalGames) gecerli ($($out.remakesExcluded) remake elendi)  $($out.firstDate) -> $($out.lastDate)"
"KAZANMA      %$($out.overallWinRate)   Rift: $($out.riftGames)  koridorlu: $($out.lanedGames)"
""
"KUYRUKLAR"; $out.byQueue | ForEach-Object { "  {0,-16} {1,4}g  %{2,-4} olum {3}  kp %{4}" -f $_.name,$_.games,$_.winRate,$_.deaths,$_.kp }
""
"DONUSUM (15. dakikadaki duruma gore kazanma)"
"  takim 1500+ onde   {0,3}g  %{1}" -f $out.conversion.teamAhead15.games, $out.conversion.teamAhead15.winRate
"  takim basabas      {0,3}g  %{1}" -f $out.conversion.teamEven15.games, $out.conversion.teamEven15.winRate
"  takim 1500+ geride {0,3}g  %{1}" -f $out.conversion.teamBehind15.games, $out.conversion.teamBehind15.winRate
"  KORIDOR onde       {0,3}g  %{1}" -f $out.conversion.laneAhead15.games, $out.conversion.laneAhead15.winRate
"  KORIDOR geride     {0,3}g  %{1}" -f $out.conversion.laneBehind15.games, $out.conversion.laneBehind15.winRate
""
"MAC SURESI"; $out.byLength | ForEach-Object { "  {0,-10} {1,3}g  %{2}" -f $_.name,$_.games,$_.winRate }
""
"ROLLER"; $out.byRole | ForEach-Object { "  {0,-9} {1,3}g  %{2,-4} cs {3,-5} gd10 {4,6}  gd15 {5,6}  olum {6,-4} kp %{7,-3} hasar %{8}" -f $_.name,$_.games,$_.winRate,$_.csPerMin,$_.goldDiff10,$_.goldDiff15,$_.deaths,$_.kp,$_.dmgShare }
""
"SAMPIYONLAR (3+ mac)"; $out.byChampion | ForEach-Object { "  {0,-14} {1,3}g  {2}W  %{3,-4} cs {4,-5} gd10 {5,6}  olum {6,-5} hasar %{7}" -f $_.name,$_.games,$_.wins,$_.winRate,$_.csPerMin,$_.goldDiff10,$_.deaths,$_.dmgShare }
""
"OLUMLER"
"  mac basi {0}   ilk 15dk {1}   YALNIZ olen {2} (tum olumlerin %{3})   ilk olum {4}. dk" -f $out.averages.deaths,$out.averages.earlyDeaths,$out.averages.soloDeaths,$out.soloDeathPct,$out.averages.firstDeathMin
"  saat dilimi:"; $out.deathClock | ForEach-Object { "    {0,2}-{1,2} dk  {2}" -f $_.from,$_.to,$_.deaths }
""
"SAATE GORE"; $out.byHour | ForEach-Object { "  {0}  {1,3}g  %{2,-4} olum {3}" -f $_.band,$_.games,$_.winRate,$_.deaths }
""
"TREND"; if ($out.trend) { $out.trend.GetEnumerator() | Sort-Object Name | ForEach-Object { "  {0,-18} {1}  ->  {2}" -f $_.Name,$_.Value.older,$_.Value.newer } }
