# Report.ps1 - turns AnalyzeFull.ps1 output into a styled Turkish HTML report.
#
#   .\AnalyzeFull.ps1 -DataDir .\data-umut-all -JsonOut .\full.json
#   .\Report.ps1 -JsonIn .\full.json -HtmlOut .\rapor.html
#
# Generated from data rather than hand-written, so re-running after new games
# produces a report with no stale numbers anywhere in it.

param(
    [Parameter(Mandatory)][string]$JsonIn,
    [Parameter(Mandatory)][string]$HtmlOut,
    [string]$Title = 'Maç Analizi'
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
Add('<p class="kicker">Tüm kuyruklar · Riot API · TR sunucusu</p>')
Add("<h1>$(E $d.account)</h1>")
Add("<p class=""sub"">$($d.totalGames) geçerli maçın tam analizi. Bütün rakamlar maç zaman çizelgesinden hesaplandı.</p>")
Add('<div class="meta">')
Add("<span>$($d.totalGames) maç</span><span>$($d.remakesExcluded) remake elendi</span>")
Add("<span>$($d.firstDate) – $($d.lastDate)</span><span>Rift: $($d.riftGames)</span>")
Add("<span>üretim: $($d.generated)</span>")
Add('</div></header>')

# ---------- summary cards ----------
$a = $d.averages
Add('<div class="cards">')
Add("<div class=""cell""><span class=""k"">Kazanma</span><span class=""v $(Tone $d.overallWinRate 53 47)"">%$($d.overallWinRate)</span><span class=""n"">$($d.totalGames) maç</span></div>")
Add("<div class=""cell""><span class=""k"">CS / dakika</span><span class=""v $(Tone $a.csPerMin 6.5 5.5)"">$($a.csPerMin)</span><span class=""n"">koridorlu maçlar</span></div>")
Add("<div class=""cell""><span class=""k"">10.dk altın farkı</span><span class=""v $(Tone $a.goldDiff10 200 -200)"">$(Sign $a.goldDiff10)</span><span class=""n"">rakibine karşı</span></div>")
Add("<div class=""cell""><span class=""k"">15.dk altın farkı</span><span class=""v $(Tone $a.goldDiff15 300 -300)"">$(Sign $a.goldDiff15)</span><span class=""n"">rakibine karşı</span></div>")
Add("<div class=""cell""><span class=""k"">Maç başı ölüm</span><span class=""v $(Tone (-$a.deaths) -6 -7.5)"">$($a.deaths)</span><span class=""n"">ilk 15dk: $($a.earlyDeaths)</span></div>")
Add("<div class=""cell""><span class=""k"">Kill katılımı</span><span class=""v $(Tone $a.kp 55 45)"">%$($a.kp)</span><span class=""n"">takım kill'lerinde</span></div>")
Add("<div class=""cell""><span class=""k"">Hasar payı</span><span class=""v $(Tone $a.dmgShare 26 20)"">%$($a.dmgShare)</span><span class=""n"">$($a.dmgPerMin)/dk</span></div>")
Add("<div class=""cell""><span class=""k"">Vizyon / dakika</span><span class=""v $(Tone $a.visionPerMin 0.9 0.6)"">$($a.visionPerMin)</span><span class=""n"">—</span></div>")
Add('</div>')

# ---------- conversion ----------
$c = $d.conversion
Add('<section><h2>Dönüşüm — avantajı kazanca çevirme</h2>')
Add('<p class="lede">15. dakikadaki duruma göre kazanma oranı. Bu tablo "koridoru kazanmak" ile "maçı kazanmak" arasındaki farkı gösterir.</p>')
Add('<div class="tw"><table><thead><tr><th>15. dakikadaki durum</th><th class="n">Maç</th><th class="n">Kazanma</th></tr></thead><tbody>')
Add("<tr class=""hi""><td><strong>Koridorda önde</strong> (+500 altın)</td><td class=""n"">$($c.laneAhead15.games)</td><td class=""n $(Tone $c.laneAhead15.winRate 65 45)"">%$($c.laneAhead15.winRate)</td></tr>")
Add("<tr><td>Takım önde (+1500 altın)</td><td class=""n"">$($c.teamAhead15.games)</td><td class=""n $(Tone $c.teamAhead15.winRate 70 55)"">%$($c.teamAhead15.winRate)</td></tr>")
Add("<tr><td>Takım başabaş</td><td class=""n"">$($c.teamEven15.games)</td><td class=""n"">%$($c.teamEven15.winRate)</td></tr>")
Add("<tr><td>Takım geride (−1500 altın)</td><td class=""n"">$($c.teamBehind15.games)</td><td class=""n"">%$($c.teamBehind15.winRate)</td></tr>")
Add("<tr class=""hi""><td><strong>Koridorda geride</strong> (−500 altın)</td><td class=""n"">$($c.laneBehind15.games)</td><td class=""n $(Tone $c.laneBehind15.winRate 40 30)"">%$($c.laneBehind15.winRate)</td></tr>")
Add('</tbody></table></div></section>')

# ---------- game length ----------
Add('<section><h2>Maç süresine göre</h2>')
Add('<p class="lede">Hangi uzunluktaki maçları kazanıyorsun? Belirli bir aralıkta düşüş varsa, oyunun o evresinde bir problem var demektir.</p>')
Add('<div class="tw"><table><thead><tr><th>Süre</th><th class="n">Maç</th><th class="n">Kazanma</th></tr></thead><tbody>')
foreach ($r in $d.byLength) {
    Add("<tr><td>$(E $r.name)</td><td class=""n"">$($r.games)</td><td class=""n $(Tone $r.winRate 55 45)"">%$($r.winRate)</td></tr>")
}
Add('</tbody></table></div></section>')

# ---------- queues ----------
Add('<section><h2>Kuyruklar</h2>')
Add('<div class="tw"><table><thead><tr><th>Kuyruk</th><th class="n">Maç</th><th class="n">Kazanma</th><th class="n">Ölüm</th><th class="n">Kill kat.</th></tr></thead><tbody>')
foreach ($r in $d.byQueue) {
    Add("<tr><td>$(E $r.name)</td><td class=""n"">$($r.games)</td><td class=""n $(Tone $r.winRate 53 47)"">%$($r.winRate)</td><td class=""n"">$($r.deaths)</td><td class=""n"">%$($r.kp)</td></tr>")
}
Add('</tbody></table></div></section>')

# ---------- roles ----------
Add('<section><h2>Roller</h2>')
Add('<div class="tw"><table><thead><tr><th>Rol</th><th class="n">Maç</th><th class="n">Kazanma</th><th class="n">CS/dk</th><th class="n">10.dk</th><th class="n">15.dk</th><th class="n">Ölüm</th><th class="n">Kill kat.</th><th class="n">Hasar</th></tr></thead><tbody>')
foreach ($r in $d.byRole) {
    $hi = if ($r.games -ge 15) { ' class="hi"' } else { '' }
    Add("<tr$hi><td><strong>$(E $r.name)</strong></td><td class=""n"">$($r.games)</td><td class=""n $(Tone $r.winRate 53 47)"">%$($r.winRate)</td><td class=""n"">$($r.csPerMin)</td><td class=""n $(Tone $r.goldDiff10 200 -200)"">$(Sign $r.goldDiff10)</td><td class=""n $(Tone $r.goldDiff15 300 -300)"">$(Sign $r.goldDiff15)</td><td class=""n"">$($r.deaths)</td><td class=""n"">%$($r.kp)</td><td class=""n"">%$($r.dmgShare)</td></tr>")
}
Add('</tbody></table></div></section>')

# ---------- champions ----------
Add('<section><h2>Şampiyonlar</h2>')
Add('<p class="lede">En az 3 maç oynananlar, maç sayısına göre sıralı.</p>')
Add('<div class="tw"><table><thead><tr><th>Şampiyon</th><th class="n">Maç</th><th class="n">Skor</th><th class="n">Kazanma</th><th class="n">CS/dk</th><th class="n">10.dk altın</th><th class="n">Ölüm</th><th class="n">Hasar</th></tr></thead><tbody>')
foreach ($r in $d.byChampion) {
    $hi = if ($r.winRate -ge 60 -and $r.games -ge 4) { ' class="hi"' } else { '' }
    Add("<tr$hi><td><strong>$(E $r.name)</strong></td><td class=""n"">$($r.games)</td><td class=""n"">$($r.wins)–$($r.games - $r.wins)</td><td class=""n $(Tone $r.winRate 58 42)"">%$($r.winRate)</td><td class=""n"">$($r.csPerMin)</td><td class=""n $(Tone $r.goldDiff10 200 -200)"">$(Sign $r.goldDiff10)</td><td class=""n $(Tone (-$r.deaths) -6 -8)"">$($r.deaths)</td><td class=""n"">%$($r.dmgShare)</td></tr>")
}
Add('</tbody></table></div></section>')

# ---------- deaths ----------
Add('<section><h2>Ölümler</h2>')
Add("<p class=""lede"">Maç başına <strong>$($a.deaths)</strong> ölüm; ilk ölüm ortalama <strong>$($a.firstDeathMin). dakikada</strong>. Bunların <strong>$($a.soloDeaths) tanesi (%$($d.soloDeathPct))</strong> yakında hiç takım arkadaşı yokken gerçekleşiyor.</p>")

$maxD = 1
foreach ($b in $d.deathClock) { if ($b.deaths -gt $maxD) { $maxD = $b.deaths } }
Add('<div class="chart">')
foreach ($b in $d.deathClock) {
    $pct = [int]($b.deaths / $maxD * 100)
    Add("<div class=""col""><div class=""val"">$($b.deaths)</div><div class=""bar"" style=""height:$pct%""></div><div class=""cap"">$($b.from)–$($b.to)</div></div>")
}
Add('</div>')
Add('<p class="dim" style="font-family:var(--mono);font-size:11.5px">ölüm sayısı / dakika aralığı</p>')
Add('<div class="note"><span class="lbl">Nasıl okunur</span><p>Yalnız ölüm oranı düşükse ölümlerin çoğu dövüşlerde oluyor demektir — bu bir konumlanma değil, dövüş seçimi problemidir. Grafikte zirve yapan aralık, oyunun hangi evresinde zorlandığını gösterir.</p></div>')
Add('</section>')

# ---------- hours ----------
if ($d.byHour -and $d.byHour.Count -gt 0) {
    Add('<section><h2>Saate göre</h2>')
    Add('<p class="lede">Yerel saat (TR). Belirli saatlerde belirgin düşüş varsa, o saatlerde oynamamak en ucuz iyileştirmedir.</p>')
    Add('<div class="tw"><table><thead><tr><th>Saat</th><th class="n">Maç</th><th class="n">Kazanma</th><th class="n">Ölüm</th></tr></thead><tbody>')
    foreach ($r in $d.byHour) {
        Add("<tr><td class=""n"">$(E $r.band)</td><td class=""n"">$($r.games)</td><td class=""n $(Tone $r.winRate 55 45)"">%$($r.winRate)</td><td class=""n"">$($r.deaths)</td></tr>")
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
            Add('<div class="note red"><span class="lbl">En büyük tek fark</span>')
            Add("<p><strong>Gündüz (08:00–20:00): $dayG maç, %$dayR kazanma.</strong><br><strong>Gece (20:00–08:00): $nightG maç, %$nightR kazanma.</strong></p>")
            Add("<p style=""margin-bottom:0"">Aradaki fark <strong>$([math]::Abs($gap)) puan</strong> ve örneklem iki tarafta da yeterli. Bu bir beceri meselesi değil, saat meselesi — yani düzeltmesi bedava olan tek şey bu.</p></div>")
        }
    }
    Add('</section>')
}

# ---------- trend ----------
if ($d.trend) {
    Add('<section><h2>Zaman içindeki değişim</h2>')
    Add('<p class="lede">Maçların eski yarısı ile yeni yarısının karşılaştırması.</p>')
    Add('<div class="tw"><table><thead><tr><th>Ölçüt</th><th class="n">Eski</th><th class="n">Yeni</th><th>Yön</th></tr></thead><tbody>')
    $labels = [ordered]@{
        winRate='Kazanma %'; csPerMin='CS / dakika'; goldDiff10='10.dk altın farkı'
        killParticipation='Kill katılımı'; deaths='Maç başı ölüm'; earlyDeaths='İlk 15 dk ölüm'
        soloDeaths='Yalnız ölüm'; visionPerMin='Vizyon / dakika'; dmgShare='Hasar payı'
    }
    $lowerBetter = @('deaths','earlyDeaths','soloDeaths')
    foreach ($k in $labels.Keys) {
        $t = $d.trend.$k
        if ($null -eq $t) { continue }
        $delta = [double]$t.newer - [double]$t.older
        $better = if ($lowerBetter -contains $k) { $delta -lt 0 } else { $delta -gt 0 }
        $flat = [math]::Abs($delta) -lt 0.05
        $cls = if ($flat) { 'dim' } elseif ($better) { 'good' } else { 'badc' }
        $word = if ($flat) { 'sabit' } elseif ($delta -gt 0) { 'arttı' } else { 'düştü' }
        Add("<tr><td>$($labels[$k])</td><td class=""n"">$($t.older)</td><td class=""n"">$($t.newer)</td><td class=""$cls"">$word</td></tr>")
    }
    Add('</tbody></table></div></section>')
}

# ---------- footer ----------
Add('<footer>')
Add("Kaynak: Riot Games Match-V5 API · $($d.totalGames) geçerli maç, $($d.remakesExcluded) remake elendi · üretim $($d.generated)<br>")
Add('Pozisyon verisi dakikada bir örnekleniyor; kare kaynaklı değerler 60 saniyeye kadar eski olabilir.<br>')
Add('Minyon verisi API''de yok, bu yüzden dalga durumu hiçbir yerde ölçülmedi.<br>')
Add('"Yalnız ölüm" = ölüm anında 4000 birim içinde takım arkadaşı yok; bu geniş bir yarıçaptır, yaklaşık bir ölçüdür.<br><br>')
Add('Bu rapor Riot Games tarafından onaylanmamıştır ve Riot Games''in görüşlerini yansıtmaz.')
Add('</footer></div>')

Set-Content -Path $HtmlOut -Value ($h -join "`n") -Encoding UTF8
Write-Host "HTML yazildi: $HtmlOut" -ForegroundColor Green

