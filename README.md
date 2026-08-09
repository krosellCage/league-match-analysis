# jungle-coaching-guide

Measures the things that actually decide League of Legends games, from your own
match history. No dependencies — PowerShell 7 and the Riot API, nothing to
install.

Most post-game tools tell you *what* happened. This one tries to answer *why*:
where you were sixty seconds before each objective died, what state you entered
your fights in, whether your lane lead ever became a win, and what time of day
you actually play worse.

It started as a jungle tool and grew a lane analyser and an HTML report
generator, so the name is now narrower than the contents.

```
DÖNÜŞÜM (15. dakikadaki duruma göre kazanma)
  takım 1500+ önde    74g  %80
  KORİDOR önde       102g  %65      <- wins lane, doesn't convert it
  takım 1500+ geride  65g  %25

SAATE GÖRE
  12:00-16:00   34g  %65
  20:00-24:00   63g  %46      <- 17 points, ~90 games each side
```

---

## Setup

Needs PowerShell 7+ (`$PSVersionTable.PSVersion`) and a Riot API key.

1. Sign in at <https://developer.riotgames.com> and copy your **development API
   key** (starts with `RGAPI-`). These expire every 24 hours.
2. Set it in your shell — it is only ever read from the environment, never
   written to disk:

```powershell
$env:RIOT_API_KEY = 'RGAPI-your-key-here'
```

## Use

```powershell
.\Fetch.ps1 -RiotId 'Name#TAG' -Platform tr1 -Count 100
.\Analyze.ps1                     # jungle
```

`Fetch.ps1` caches every match to `.\data\`, so running it again only downloads
games you don't already have. Nothing else touches the network.

Supported platforms: `na1 br1 la1 la2 euw1 eun1 tr1 ru me1 kr jp1 oc1 ph2 sg2
th2 tw2 vn2` — the regional routing cluster is derived automatically.

---

## The four scripts

| Script | For | Output |
|---|---|---|
| `Fetch.ps1` | Everyone | Cached raw JSON in `data/` |
| `Analyze.ps1` | Junglers | Console report + `facts.json` |
| `AnalyzeLane.ps1` | Mid / bot / top | Console report + summary JSON |
| `AnalyzeFull.ps1` | Any role, every queue | Wide metric set as JSON |
| `Report.ps1` | — | Styled HTML report from that JSON |

Pick the analyser that matches how you play. The jungle detectors are
meaningless for a mid laner, and lane differentials are meaningless for a
jungler, so they are deliberately separate rather than one script with flags.

### Jungle — `Analyze.ps1`

- **Objective setup.** For every dragon, baron, herald and grub that died,
  where were you 60 seconds earlier? Anchored on the objective's own kill event
  and its own position, so no spawn timers are hardcoded and nothing breaks on
  a patch. The number that matters is how often you were absent for objectives
  *the enemy took*.
- **You versus the enemy jungler**, both directions — split by whether anyone
  assisted, whose half of the map it happened in, and what level and HP each of
  you entered on. Counting only your deaths answers a question nobody asked.
- **Invade pressure**, **vision spend**, **champion pool**, **queue discipline**
  (sessions rebuilt from timestamps, and games queued while already on a
  two-loss streak), and an **older half vs newer half** trend.

### Lane — `AnalyzeLane.ps1`

Everything measured as a difference against the enemy in *your* position: gold,
CS and XP at 10 and 15 minutes, deaths inside the laning phase, damage share,
and per-role and per-champion splits.

### Everything — `AnalyzeFull.ps1`

The wide pass, across every queue:

- **Conversion** — win rate *given* a lead at 15 minutes, separately for your
  lane and for the whole team. This is the metric that separates winning your
  lane from winning games.
- **Win rate by game length**, which localises a collapse to a phase of the game.
- **Death clock** — deaths bucketed into five-minute windows.
- **Solo deaths** — how many happened with no ally within 4000 units.
- **Win rate by hour of day**, in local time.
- Queue, role, side, champion, damage share, gold share, damage per 1000 gold,
  time to first death, and a trend split.

### Report — `Report.ps1`

Turns `AnalyzeFull.ps1`'s JSON into a self-contained HTML report (currently
Turkish), light and dark themed, with a death-distribution chart. Generated from
data rather than hand-written, so re-running after new games produces a report
with no stale numbers anywhere in it.

```powershell
.\AnalyzeFull.ps1 -DataDir .\data -JsonOut .\full.json
.\Report.ps1 -JsonIn .\full.json -HtmlOut .\rapor.html
```

---

## Limits worth knowing

These are properties of the data, not bugs.

- **Position frames sample once per minute.** Anything derived from a frame can
  be up to 60 seconds stale. Kill and objective events carry exact positions and
  are used as anchors where possible. Staleness is recorded, not hidden.
- **There is no minion data in the API.** Wave state cannot be measured, so
  nothing here will ever explain a gank in terms of the wave. That gap is
  permanent.
- **`WARD_PLACED` carries no position** — only creator, timestamp and ward type.
  Wards can be counted and timed but never mapped, which is why control wards
  bought is used as the vision metric instead.
- **"No assists" is a proxy for a 1v1, not a measurement of one.** An ally may
  have been present and dealt no damage. Likewise "solo death" uses a 4000-unit
  radius, which is generous.
- **Small samples say nothing.** Twenty games minimum before per-game averages
  mean much, though per-event metrics reach useful sample sizes sooner.

---

## Files

| | |
|---|---|
| `Riot.ps1` | API client: routing, auth, retries, pacing, pagination |
| `Fetch.ps1` | Resolve account, list matches, cache raw JSON |
| `Analyze.ps1` | Jungle detectors |
| `AnalyzeLane.ps1` | Lane differentials |
| `AnalyzeFull.ps1` | Wide metric set across all queues |
| `Report.ps1` | HTML report generator |
| `data*/` | Local caches — gitignored, never committed |

Cache directories and generated reports are gitignored by pattern, because they
contain real accounts' match history and PUUIDs.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `HTTP 401/403` | Key expired. Development keys last 24 hours. |
| `HTTP 404` on account lookup | Riot ID typo, or wrong `-Platform`. |
| `No matches returned` | No recent games in that queue. Try `-Queue 0`. |
| `No games matched the filter` | You weren't jungle. Try `-JungleOnly:$false`. |

---

## License

MIT — see [LICENSE](LICENSE).

---

jungle-coaching-guide isn't endorsed by Riot Games and doesn't reflect the views
or opinions of Riot Games or anyone officially involved in producing or managing
Riot Games properties. Riot Games and all associated properties are trademarks
or registered trademarks of Riot Games, Inc.
