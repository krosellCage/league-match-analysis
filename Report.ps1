# Report.ps1 - turns AnalyzeFull.ps1 output into a styled HTML report.
#
#   .\AnalyzeFull.ps1 -DataDir .\data -JsonOut .\full.json
#   .\Report.ps1 -JsonIn .\full.json -HtmlOut .\report.html
#
# Generated from data rather than hand-written, so re-running after new games
# produces a report with no stale numbers anywhere in it.

param(
    [Parameter(Mandatory)][string]$JsonIn,
    [Parameter(Mandatory)][string]$HtmlOut,
    [string]$Title = 'Match Analysis'
)

$ErrorActionPreference = 'Stop'
$d = Get-Content $JsonIn -Raw | ConvertFrom-Json

function E([string]$s) {
    if ($null -eq $s) { return '' }
    return $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
}
# NOTE: do not name this Cls - that is a built-in alias for Clear-Host, and
# aliases resolve BEFORE functions, so the function would never be called.
function Tone($value, $goodAbove, $badBelow) {
    if ($null -eq $value) { return 'dim' }
    if ($value -ge $goodAbove) { return 'good' }
    if ($value -le $badBelow)  { return 'badc' }
    return ''
}
function Sign($n) {
    if ($null -eq $n) { return '—' }
    if ($n -gt 0) { return "+$n" }
    return "$n"
}

$h = [System.Collections.Generic.List[string]]::new()
function Add($s) { $script:h.Add($s) }

Add("<title>$(E $Title) — $(E $d.account)</title>")

Add(@'
<style>
  :root{
    --ground:#F7F5F6;--surface:#FFFFFF;--surface2:#EFEAEC;
    --ink:#1C1519;--soft:#5B4F55;--faint:#8A7C82;
    --line:#E4DDE0;--line2:#CDC2C7;
    --accent:#8E2F5E;--wash:#F6EAF0;
    --ok:#1C7A4C;--warn:#8F5E12;--bad:#AE2F27;
    --shadow:0 1px 2px rgba(28,21,25,.05),0 8px 24px rgba(28,21,25,.06);
  }
  @media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
    --ground:#141013;--surface:#1D171C;--surface2:#251E24;
    --ink:#EFE7EB;--soft:#AB9BA3;--faint:#7C6E75;
    --line:#2E262C;--line2:#3E343B;
    --accent:#E893BA;--wash:#2A1A23;
    --ok:#4FBE86;--warn:#E0A44E;--bad:#E8746B;
    --shadow:0 1px 2px rgba(0,0,0,.4),0 10px 30px rgba(0,0,0,.35);
  }}
  :root[data-theme="dark"]{
    --ground:#141013;--surface:#1D171C;--surface2:#251E24;
    --ink:#EFE7EB;--soft:#AB9BA3;--faint:#7C6E75;
    --line:#2E262C;--line2:#3E343B;
    --accent:#E893BA;--wash:#2A1A23;
    --ok:#4FBE86;--warn:#E0A44E;--bad:#E8746B;
    --shadow:0 1px 2px rgba(0,0,0,.4),0 10px 30px rgba(0,0,0,.35);
  }
  :root{--sans:"Segoe UI",system-ui,-apple-system,"Helvetica Neue",Arial,sans-serif;
        --mono:"Cascadia Mono","Consolas",ui-monospace,Menlo,monospace}
  *{box-sizing:border-box}
  body{background:var(--ground);color:var(--ink);font-family:var(--sans);
       font-size:16.5px;line-height:1.6;margin:0;-webkit-font-smoothing:antialiased}
  .wrap{max-width:1020px;margin:0 auto;padding:0 22px 100px}
  header{padding:54px 0 0}
  .kicker{font-family:var(--mono);font-size:11px;letter-spacing:.18em;text-transform:uppercase;
          color:var(--accent);margin:0 0 14px}
  h1{font-size:clamp(28px,5vw,44px);line-height:1.06;letter-spacing:-.02em;margin:0 0 10px;
     font-weight:700;text-wrap:balance;word-break:break-word}
  .sub{color:var(--soft);font-size:17px;margin:0}
  .meta{font-family:var(--mono);font-size:12px;color:var(--faint);border-top:1px solid var(--line);
        margin-top:24px;padding-top:12px;display:flex;gap:18px;flex-wrap:wrap}
  section{padding-top:44px}
  h2{font-size:clamp(19px,2.9vw,25px);margin:0 0 6px;letter-spacing:-.01em;
     border-top:1px solid var(--line2);padding-top:14px;text-wrap:balance}
  .lede{color:var(--soft);margin:0 0 14px;max-width:68ch}
  p{margin:0 0 13px;max-width:70ch}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:1px;
         background:var(--line);border:1px solid var(--line);margin:22px 0}
  .cell{background:var(--surface);padding:15px 17px}
  .cell .k{font-family:var(--mono);font-size:10px;letter-spacing:.13em;text-transform:uppercase;
           color:var(--faint);display:block;margin-bottom:8px}
  .cell .v{font-family:var(--mono);font-size:clamp(22px,3vw,30px);line-height:1;
           font-variant-numeric:tabular-nums;letter-spacing:-.02em;display:block}
  .cell .n{font-size:12px;color:var(--faint);display:block;margin-top:7px}
  .v.good{color:var(--ok)}.v.badc{color:var(--bad)}.v.warn{color:var(--warn)}
  .tw{overflow-x:auto;border:1px solid var(--line);background:var(--surface);margin:16px 0}
  table{border-collapse:collapse;width:100%;min-width:600px;font-size:14.5px}
  th,td{text-align:left;padding:9px 13px;border-bottom:1px solid var(--line);vertical-align:top}
  thead th{font-family:var(--mono);font-size:10px;letter-spacing:.11em;text-transform:uppercase;
           color:var(--faint);font-weight:400;background:var(--surface2);border-bottom:1px solid var(--line2)}
  tbody tr:last-child td{border-bottom:none}
  td.n,th.n{font-family:var(--mono);font-variant-numeric:tabular-nums;white-space:nowrap}
  tr.hi td{background:var(--wash)}
  .good{color:var(--ok);font-weight:600}.badc{color:var(--bad);font-weight:600}
  .warnc{color:var(--warn);font-weight:600}.dim{color:var(--faint)}
  .note{background:var(--surface);border:1px solid var(--line);border-left:3px solid var(--accent);
        padding:15px 17px;margin:18px 0}
  .note.red{border-left-color:var(--bad)}
  .note>:last-child{margin-bottom:0}
  .note .lbl{font-family:var(--mono);font-size:10.5px;letter-spacing:.13em;text-transform:uppercase;
             color:var(--accent);display:block;margin-bottom:7px}
  .note.red .lbl{color:var(--bad)}
  .chart{display:flex;align-items:flex-end;gap:5px;height:150px;margin:18px 0 6px;
         padding:0 2px;overflow-x:auto}
  .chart .col{flex:1;min-width:26px;display:flex;flex-direction:column;justify-content:flex-end;height:100%}
  .chart .bar{background:var(--accent);width:100%;border-radius:1px 1px 0 0;min-height:2px}
  .chart .cap{font-family:var(--mono);font-size:9.5px;color:var(--faint);text-align:center;
              margin-top:6px;white-space:nowrap}
  .chart .val{font-family:var(--mono);font-size:10.5px;color:var(--soft);text-align:center;margin-bottom:4px}
  footer{margin-top:56px;padding-top:18px;border-top:1px solid var(--line2);
         font-family:var(--mono);font-size:11.5px;color:var(--faint);line-height:1.75}
</style>
'@)

Add('<div class="wrap">')

# ---------- header ----------
Add('<header>')
Add('<p class="kicker">All queues · Riot Match-V5 API</p>')
Add("<h1>$(E $d.account)</h1>")
Add("<p class=""sub"">Full analysis of $($d.totalGames) games. Every number is computed from the match timeline — nothing is estimated.</p>")
Add('<div class="meta">')
Add("<span>$($d.totalGames) games</span><span>$($d.remakesExcluded) remakes excluded</span>")
Add("<span>$($d.firstDate) – $($d.lastDate)</span><span>Rift: $($d.riftGames)</span>")
Add("<span>generated $($d.generated)</span>")
Add('</div></header>')

# ---------- summary cards ----------
$a = $d.averages
Add('<div class="cards">')
Add("<div class=""cell""><span class=""k"">Win rate</span><span class=""v $(Tone $d.overallWinRate 53 47)"">$($d.overallWinRate)%</span><span class=""n"">$($d.totalGames) games</span></div>")
Add("<div class=""cell""><span class=""k"">CS / min</span><span class=""v $(Tone $a.csPerMin 6.5 5.5)"">$($a.csPerMin)</span><span class=""n"">games with a lane</span></div>")
Add("<div class=""cell""><span class=""k"">Gold diff @10</span><span class=""v $(Tone $a.goldDiff10 200 -200)"">$(Sign $a.goldDiff10)</span><span class=""n"">vs your opponent</span></div>")
Add("<div class=""cell""><span class=""k"">Gold diff @15</span><span class=""v $(Tone $a.goldDiff15 300 -300)"">$(Sign $a.goldDiff15)</span><span class=""n"">vs your opponent</span></div>")
Add("<div class=""cell""><span class=""k"">Deaths / game</span><span class=""v $(Tone (-$a.deaths) -6 -7.5)"">$($a.deaths)</span><span class=""n"">first 15 min: $($a.earlyDeaths)</span></div>")
Add("<div class=""cell""><span class=""k"">Kill participation</span><span class=""v $(Tone $a.kp 55 45)"">$($a.kp)%</span><span class=""n"">of team kills</span></div>")
Add("<div class=""cell""><span class=""k"">Damage share</span><span class=""v $(Tone $a.dmgShare 26 20)"">$($a.dmgShare)%</span><span class=""n"">$($a.dmgPerMin)/min</span></div>")
Add("<div class=""cell""><span class=""k"">Vision / min</span><span class=""v $(Tone $a.visionPerMin 0.9 0.6)"">$($a.visionPerMin)</span><span class=""n"">vision score</span></div>")
Add('</div>')

# ---------- conversion ----------
$c = $d.conversion
Add('<section><h2>Conversion — turning a lead into a win</h2>')
Add('<p class="lede">Win rate <em>given</em> the state at 15 minutes. This is the table that separates winning your lane from winning games.</p>')
Add('<div class="tw"><table><thead><tr><th>State at 15 minutes</th><th class="n">Games</th><th class="n">Win rate</th></tr></thead><tbody>')
Add("<tr class=""hi""><td><strong>Your lane ahead</strong> (+500 gold)</td><td class=""n"">$($c.laneAhead15.games)</td><td class=""n $(Tone $c.laneAhead15.winRate 65 45)"">$($c.laneAhead15.winRate)%</td></tr>")
Add("<tr><td>Team ahead (+1500 gold)</td><td class=""n"">$($c.teamAhead15.games)</td><td class=""n $(Tone $c.teamAhead15.winRate 70 55)"">$($c.teamAhead15.winRate)%</td></tr>")
Add("<tr><td>Team even</td><td class=""n"">$($c.teamEven15.games)</td><td class=""n"">$($c.teamEven15.winRate)%</td></tr>")
Add("<tr><td>Team behind (−1500 gold)</td><td class=""n"">$($c.teamBehind15.games)</td><td class=""n"">$($c.teamBehind15.winRate)%</td></tr>")
Add("<tr class=""hi""><td><strong>Your lane behind</strong> (−500 gold)</td><td class=""n"">$($c.laneBehind15.games)</td><td class=""n $(Tone $c.laneBehind15.winRate 40 30)"">$($c.laneBehind15.winRate)%</td></tr>")
Add('</tbody></table></div></section>')

# ---------- game length ----------
Add('<section><h2>By game length</h2>')
Add('<p class="lede">Which lengths of game do you win? A dip in one band localises the problem to a phase of the game.</p>')
Add('<div class="tw"><table><thead><tr><th>Length</th><th class="n">Games</th><th class="n">Win rate</th></tr></thead><tbody>')
foreach ($r in $d.byLength) {
    Add("<tr><td>$(E $r.name)</td><td class=""n"">$($r.games)</td><td class=""n $(Tone $r.winRate 55 45)"">$($r.winRate)%</td></tr>")
}
Add('</tbody></table></div></section>')

# ---------- queues ----------
Add('<section><h2>By queue</h2>')
Add('<div class="tw"><table><thead><tr><th>Queue</th><th class="n">Games</th><th class="n">Win rate</th><th class="n">Deaths</th><th class="n">Kill part.</th></tr></thead><tbody>')
foreach ($r in $d.byQueue) {
    Add("<tr><td>$(E $r.name)</td><td class=""n"">$($r.games)</td><td class=""n $(Tone $r.winRate 53 47)"">$($r.winRate)%</td><td class=""n"">$($r.deaths)</td><td class=""n"">$($r.kp)%</td></tr>")
}
Add('</tbody></table></div>')
Add('<div class="note"><span class="lbl">Read with care</span><p>Arena and other non-Rift modes have different scoring, so their kill participation and death numbers are not comparable to Summoner''s Rift. Lane metrics elsewhere in this report use Rift games only.</p></div>')
Add('</section>')

# ---------- roles ----------
Add('<section><h2>By role</h2>')
Add('<div class="tw"><table><thead><tr><th>Role</th><th class="n">Games</th><th class="n">Win rate</th><th class="n">CS/min</th><th class="n">@10</th><th class="n">@15</th><th class="n">Deaths</th><th class="n">Kill part.</th><th class="n">Damage</th></tr></thead><tbody>')
foreach ($r in $d.byRole) {
    $hi = if ($r.games -ge 15) { ' class="hi"' } else { '' }
    Add("<tr$hi><td><strong>$(E $r.name)</strong></td><td class=""n"">$($r.games)</td><td class=""n $(Tone $r.winRate 53 47)"">$($r.winRate)%</td><td class=""n"">$($r.csPerMin)</td><td class=""n $(Tone $r.goldDiff10 200 -200)"">$(Sign $r.goldDiff10)</td><td class=""n $(Tone $r.goldDiff15 300 -300)"">$(Sign $r.goldDiff15)</td><td class=""n"">$($r.deaths)</td><td class=""n"">$($r.kp)%</td><td class=""n"">$($r.dmgShare)%</td></tr>")
}
Add('</tbody></table></div></section>')

# ---------- champions ----------
Add('<section><h2>Champions</h2>')
Add('<p class="lede">Three games or more, ordered by games played.</p>')
Add('<div class="tw"><table><thead><tr><th>Champion</th><th class="n">Games</th><th class="n">Record</th><th class="n">Win rate</th><th class="n">CS/min</th><th class="n">Gold @10</th><th class="n">Deaths</th><th class="n">Damage</th></tr></thead><tbody>')
foreach ($r in $d.byChampion) {
    $hi = if ($r.winRate -ge 60 -and $r.games -ge 4) { ' class="hi"' } else { '' }
    Add("<tr$hi><td><strong>$(E $r.name)</strong></td><td class=""n"">$($r.games)</td><td class=""n"">$($r.wins)–$($r.games - $r.wins)</td><td class=""n $(Tone $r.winRate 58 42)"">$($r.winRate)%</td><td class=""n"">$($r.csPerMin)</td><td class=""n $(Tone $r.goldDiff10 200 -200)"">$(Sign $r.goldDiff10)</td><td class=""n $(Tone (-$r.deaths) -6 -8)"">$($r.deaths)</td><td class=""n"">$($r.dmgShare)%</td></tr>")
}
Add('</tbody></table></div></section>')

# ---------- deaths ----------
Add('<section><h2>Deaths</h2>')
Add("<p class=""lede""><strong>$($a.deaths)</strong> per game, with the first at <strong>$($a.firstDeathMin) minutes</strong> on average. <strong>$($a.soloDeaths) of them ($($d.soloDeathPct)%)</strong> happened with no teammate anywhere nearby.</p>")

$maxD = 1
foreach ($b in $d.deathClock) { if ($b.deaths -gt $maxD) { $maxD = $b.deaths } }
Add('<div class="chart">')
foreach ($b in $d.deathClock) {
    $pct = [int]($b.deaths / $maxD * 100)
    Add("<div class=""col""><div class=""val"">$($b.deaths)</div><div class=""bar"" style=""height:$pct%""></div><div class=""cap"">$($b.from)–$($b.to)</div></div>")
}
Add('</div>')
Add('<p class="dim" style="font-family:var(--mono);font-size:11.5px">deaths per minute band</p>')
Add('<div class="note"><span class="lbl">How to read this</span><p>A low share of solo deaths means most deaths happen inside fights — that is a fight-selection problem, not a positioning one. The peak band in the chart tells you which phase of the game you struggle in.</p></div>')
Add('</section>')

# ---------- hours ----------
if ($d.byHour -and $d.byHour.Count -gt 0) {
    Add('<section><h2>By time of day</h2>')
    Add('<p class="lede">Local time. A clear dip in some bands makes not playing then the cheapest improvement available.</p>')
    Add('<div class="tw"><table><thead><tr><th>Hours</th><th class="n">Games</th><th class="n">Win rate</th><th class="n">Deaths</th></tr></thead><tbody>')
    foreach ($r in $d.byHour) {
        Add("<tr><td class=""n"">$(E $r.band)</td><td class=""n"">$($r.games)</td><td class=""n $(Tone $r.winRate 55 45)"">$($r.winRate)%</td><td class=""n"">$($r.deaths)</td></tr>")
    }
    Add('</tbody></table></div>')

    # Day/night split, weighted by games. Usually the single largest lever a
    # player has, and it is a scheduling decision rather than a skill.
    $dayG=0; $dayW=0.0; $nightG=0; $nightW=0.0
    foreach ($r in $d.byHour) {
        $start = [int]($r.band.Substring(0,2))
        if ($start -ge 8 -and $start -lt 20) { $dayG += $r.games;   $dayW   += $r.games * $r.winRate }
        else                                 { $nightG += $r.games; $nightW += $r.games * $r.winRate }
    }
    if ($dayG -gt 0 -and $nightG -gt 0) {
        $dayR = [int]($dayW/$dayG); $nightR = [int]($nightW/$nightG)
        $gap = $dayR - $nightR
        if ([math]::Abs($gap) -ge 5) {
            Add('<div class="note red"><span class="lbl">The single biggest gap</span>')
            Add("<p><strong>Daytime (08:00–20:00): $dayG games, $dayR% win rate.</strong><br><strong>Night (20:00–08:00): $nightG games, $nightR% win rate.</strong></p>")
            Add("<p style=""margin-bottom:0"">That is a <strong>$([math]::Abs($gap)) point</strong> difference with a real sample on both sides. This is not a skill problem, it is a scheduling one — which makes it the only thing here that is free to fix.</p></div>")
        }
    }
    Add('</section>')
}

# ---------- trend ----------
if ($d.trend) {
    Add('<section><h2>Change over time</h2>')
    Add('<p class="lede">The older half of these games against the newer half.</p>')
    Add('<div class="tw"><table><thead><tr><th>Metric</th><th class="n">Older</th><th class="n">Newer</th><th>Direction</th></tr></thead><tbody>')
    $labels = [ordered]@{
        winRate='Win rate'; csPerMin='CS / min'; goldDiff10='Gold diff @10'
        killParticipation='Kill participation'; deaths='Deaths per game'; earlyDeaths='Deaths in first 15 min'
        soloDeaths='Solo deaths'; visionPerMin='Vision / min'; dmgShare='Damage share'
    }
    $lowerBetter = @('deaths','earlyDeaths','soloDeaths')
    foreach ($k in $labels.Keys) {
        $t = $d.trend.$k
        if ($null -eq $t) { continue }
        $delta = [double]$t.newer - [double]$t.older
        $better = if ($lowerBetter -contains $k) { $delta -lt 0 } else { $delta -gt 0 }
        $flat = [math]::Abs($delta) -lt 0.05
        $cls = if ($flat) { 'dim' } elseif ($better) { 'good' } else { 'badc' }
        $word = if ($flat) { 'flat' } elseif ($delta -gt 0) { 'up' } else { 'down' }
        Add("<tr><td>$($labels[$k])</td><td class=""n"">$($t.older)</td><td class=""n"">$($t.newer)</td><td class=""$cls"">$word</td></tr>")
    }
    Add('</tbody></table></div></section>')
}

# ---------- footer ----------
Add('<footer>')
Add("Source: Riot Games Match-V5 API · $($d.totalGames) valid games, $($d.remakesExcluded) remakes excluded · generated $($d.generated)<br>")
Add('Position frames sample once per minute, so frame-derived values can be up to 60 seconds stale.<br>')
Add('There is no minion data in the API, so wave state is never measured anywhere in this report.<br>')
Add('"Solo death" means no teammate within 4000 units at the moment of death — a generous radius, so treat it as approximate.<br><br>')
Add('This report is not endorsed by Riot Games and does not reflect the views or opinions of Riot Games.')
Add('</footer></div>')

Set-Content -Path $HtmlOut -Value ($h -join "`n") -Encoding UTF8
Write-Host "HTML written: $HtmlOut" -ForegroundColor Green
