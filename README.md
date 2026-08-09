# jungle-coaching-guide

Measures the things that actually decide jungle games, from your own League of
Legends match history. No dependencies — PowerShell 7 and the Riot API, nothing
to install.

Most post-game tools tell you what happened. This one tries to answer *why*:
where you were sixty seconds before each objective died, what state you entered
your fights in, and whose half of the map they happened in.

```
OBJECTIVE SETUP
  Where you were 60 seconds before each objective died.
  at pit       25  (17%)
  arriving     38  (26%)
  absent       82  (57%)
  SETUP RATE: 43%  of 145 objectives
  On objectives the ENEMY took, you were absent 39 of 72 times (54%).

YOU vs THE ENEMY JUNGLER  -  every interaction, both directions
  You killed them 29 times. They killed you 41 times.
  Clean 1v1s only: you 3 - 14 them   =  18% solo duel win rate
  With help on either side: you 26 - 27 them

  HP entering the fight:
    fights you LOST: you 73%  them 83%
    fights you WON:  you 82%  them 84%
```

---

## Setup

Needs PowerShell 7+ (`$PSVersionTable.PSVersion`) and a Riot API key.

1. Sign in at <https://developer.riotgames.com> and copy your **development API
   key** (starts with `RGAPI-`). These expire every 24 hours.
2. Set it in your shell:

```powershell
$env:RIOT_API_KEY = 'RGAPI-your-key-here'
```

The key is only ever read from the environment. It is never written to disk.

## Use

```powershell
.\Fetch.ps1 -RiotId 'Name#TAG' -Platform tr1
.\Analyze.ps1
```

Or set your identity once per session and drop the parameters:

```powershell
$env:RIOT_ID = 'Name#TAG'
$env:RIOT_PLATFORM = 'euw1'
.\Fetch.ps1
.\Analyze.ps1
```

`Fetch.ps1` caches every match to `.\data\`, so running it again only downloads
games you don't already have. `Analyze.ps1` never touches the network.

Supported platforms: `na1 br1 la1 la2 euw1 eun1 tr1 ru me1 kr jp1 oc1 ph2 sg2
th2 tw2 vn2` — the regional routing cluster is derived automatically.

### Options

```powershell
.\Fetch.ps1 -Count 100              # more games (pages automatically past 100)
.\Fetch.ps1 -Queue 440              # flex; 420 solo/duo (default); 0 all queues

.\Analyze.ps1 -JungleOnly:$false    # include games you didn't jungle
.\Analyze.ps1 -MinDurationMinutes 5 # remake threshold (default 8)
.\Analyze.ps1 -MarkdownOut report.md
```

---

## What it measures

**Objective setup.** For every dragon, baron, herald and grub that died in your
games, where were you sixty seconds earlier? Anchored on the objective's own
kill event and its own position, so no spawn timers are hardcoded and nothing
breaks on a patch. The number that matters is how often you were absent for
objectives *the enemy took*.

**You versus the enemy jungler.** Every kill exchange between you, in both
directions — split by whether anyone assisted, whose half of the map it happened
in, and what level and HP each of you entered on. Counting only your deaths
answers a question nobody asked.

**Invade pressure.** How much of the first fifteen minutes the enemy jungler
spent inside your half of the map.

**Vision spend.** Wards placed and control wards bought per game, plus how many
games you bought none at all.

**Champion pool.** Games, record, deaths and farm per champion.

**Queue discipline.** Sessions reconstructed from game timestamps, and how many
games you queued while already on a two-loss streak.

**Trend.** Older half of your games versus the newer half, so you can tell
whether something you changed actually worked.

---

## Limits worth knowing

These are properties of the data, not bugs.

- **Position frames sample once per minute.** Anything derived from a frame can
  be up to 60 seconds stale. Kill and objective events carry exact positions,
  and are used as anchors where possible. Staleness is recorded in `facts.json`
  rather than hidden.
- **There is no minion data in the API.** Wave state cannot be measured, so
  nothing here will ever explain a gank in terms of the wave. That gap is
  permanent.
- **`WARD_PLACED` carries no position** — only creator, timestamp and ward type.
  Wards can be counted and timed but never mapped, which is why control wards
  bought is used as the vision metric instead.
- **"No assists" is a proxy for a 1v1, not a measurement of one.** An ally may
  have been present and dealt no damage.
- **Small samples say nothing.** Twenty games minimum before per-game averages
  mean much, though per-event metrics reach useful sample sizes sooner.

---

## Files

| | |
|---|---|
| `Riot.ps1` | API client: routing, auth, retries, pacing, pagination |
| `Fetch.ps1` | Resolve account, list matches, cache raw JSON |
| `Analyze.ps1` | Detectors and the report |
| `data/` | Local cache — gitignored, never committed |

`data/facts.json` is a compact structured summary, a few KB rather than the
megabytes of raw timeline. It's the file to hand to an LLM for a written review.

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
