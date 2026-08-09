# Riot.ps1 - thin client for the Riot Games API.
# Dot-source this: . .\Riot.ps1
#
# Two different routing systems exist and mixing them up is the classic first
# bug. Summoner-level endpoints use the PLATFORM (tr1, euw1, na1...). Account-V1
# and Match-V5 use the REGIONAL cluster that platform belongs to.

$script:PlatformToRegional = @{
    'na1'='americas'; 'br1'='americas'; 'la1'='americas'; 'la2'='americas'
    'euw1'='europe';  'eun1'='europe';  'tr1'='europe';   'ru'='europe';  'me1'='europe'
    'kr'='asia';      'jp1'='asia'
    'oc1'='sea';      'ph2'='sea';      'sg2'='sea';      'th2'='sea';    'tw2'='sea'; 'vn2'='sea'
}

$script:Platform = 'tr1'
$script:Regional = 'europe'

# Dev keys allow roughly 20 req/s and 100 req/2min. This tool makes about two
# requests per game, so a small fixed pause stays far below every limit without
# needing token-bucket bookkeeping.
$script:PaceSeconds = 1.3

function Set-RiotPlatform {
    <# Sets the platform and derives the matching regional cluster. #>
    param([Parameter(Mandatory)][string]$Platform)

    $p = $Platform.ToLowerInvariant()
    if (-not $script:PlatformToRegional.ContainsKey($p)) {
        throw "Unknown platform '$Platform'. Known: $($script:PlatformToRegional.Keys -join ', ')"
    }
    $script:Platform = $p
    $script:Regional = $script:PlatformToRegional[$p]
}

function Get-RiotPlatform { return $script:Platform }
function Get-RiotRegional { return $script:Regional }

function Get-RiotKey {
    if ([string]::IsNullOrWhiteSpace($env:RIOT_API_KEY)) {
        throw @"
RIOT_API_KEY is not set in this shell.

  1. Sign in at https://developer.riotgames.com
  2. Copy the DEVELOPMENT API KEY (starts with RGAPI-)
  3. Run:  `$env:RIOT_API_KEY = 'RGAPI-your-key-here'

Development keys expire every 24 hours. Regenerate and re-run when it dies.
"@
    }
    return $env:RIOT_API_KEY
}

function Invoke-RiotRaw {
    <#
      Returns the raw JSON text of a Riot API response. Keeping the raw text
      means the on-disk cache is exactly what Riot sent, not something reshaped
      by PowerShell's object conversion.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$MaxTries = 4
    )

    $headers = @{ 'X-Riot-Token' = (Get-RiotKey) }

    for ($try = 1; $try -le $MaxTries; $try++) {
        $shouldRetry = $false
        $content = $null

        try {
            $resp = Invoke-WebRequest -Uri $Url -Headers $headers -Method Get -TimeoutSec 25
            $content = $resp.Content
        }
        catch {
            $code = 0
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                $code = [int]$_.Exception.Response.StatusCode
            }

            switch ($code) {
                429 {
                    Write-Host "  rate limited, waiting 15s..." -ForegroundColor DarkYellow
                    Start-Sleep -Seconds 15
                    $shouldRetry = $true
                }
                401 { throw "HTTP 401 - the API key was rejected. Development keys expire every 24 hours; regenerate at https://developer.riotgames.com" }
                403 { throw "HTTP 403 - the API key was rejected or lacks access. Development keys expire every 24 hours; regenerate at https://developer.riotgames.com" }
                404 { throw "HTTP 404 - not found. Check the Riot ID spelling and that the platform ('$script:Platform' -> '$script:Regional') is right for this account.`nURL: $Url" }
                default {
                    if ($code -ge 500 -and $code -le 599) {
                        Start-Sleep -Seconds (3 * $try)
                        $shouldRetry = $true
                    } else {
                        throw "HTTP $code requesting $Url`n$($_.Exception.Message)"
                    }
                }
            }
        }

        if (-not $shouldRetry) {
            Start-Sleep -Milliseconds ([int]($script:PaceSeconds * 1000))
            return $content
        }
    }

    throw "Gave up after $MaxTries attempts: $Url"
}

function Get-RiotAccount {
    param(
        [Parameter(Mandatory)][string]$GameName,
        [Parameter(Mandatory)][string]$TagLine
    )
    $g = [uri]::EscapeDataString($GameName)
    $t = [uri]::EscapeDataString($TagLine)
    $url = "https://$script:Regional.api.riotgames.com/riot/account/v1/accounts/by-riot-id/$g/$t"
    return (Invoke-RiotRaw -Url $url | ConvertFrom-Json)
}

function Get-MatchIds {
    param(
        [Parameter(Mandatory)][string]$Puuid,
        [int]$Count = 20,
        [int]$Queue = 420   # 420 = ranked solo/duo, 440 = flex, 0 = all queues
    )
    # Riot caps count at 100 per request, so page for anything larger.
    $all = @()
    $start = 0
    while ($all.Count -lt $Count) {
        $take = [math]::Min(100, $Count - $all.Count)
        $url = "https://$script:Regional.api.riotgames.com/lol/match/v5/matches/by-puuid/$Puuid/ids?start=$start&count=$take"
        if ($Queue -gt 0) { $url += "&queue=$Queue" }
        $page = @(Invoke-RiotRaw -Url $url | ConvertFrom-Json)
        if ($page.Count -eq 0) { break }              # no more history
        $all += $page
        $start += $page.Count
        if ($page.Count -lt $take) { break }          # short page = end of history
    }
    return $all
}

function Get-MatchRaw {
    param([Parameter(Mandatory)][string]$MatchId)
    return Invoke-RiotRaw -Url "https://$script:Regional.api.riotgames.com/lol/match/v5/matches/$MatchId"
}

function Get-TimelineRaw {
    param([Parameter(Mandatory)][string]$MatchId)
    return Invoke-RiotRaw -Url "https://$script:Regional.api.riotgames.com/lol/match/v5/matches/$MatchId/timeline"
}
