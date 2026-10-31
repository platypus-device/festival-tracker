$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1") -Force

function Assert-Yts {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message" -ForegroundColor Green
}

$now = [datetimeoffset]"2026-10-31T01:00:00Z"
$resource = [pscustomobject]@{ url = "https://yts.gg/torrent/download/$('a' * 40)"; quality = "1080p"; video_codec = "x265"; type = "bluray"; bit_depth = "10"; audio_channels = "5.1"; size_bytes = 2147483648 }
$foundPayload = [pscustomobject]@{ status = "ok"; data = [pscustomobject]@{ movie_count = 1; movies = @([pscustomobject]@{ imdb_code = "tt1001"; torrents = @($resource) }) } }
$missingPayload = [pscustomobject]@{ status = "ok"; data = [pscustomobject]@{ movie_count = 0 } }
$foundResult = ConvertFrom-YtsCatalogResponse -Payload $foundPayload -ImdbId "tt1001" -Now $now
Assert-Yts ($foundResult.status -eq "found" -and $foundResult.torrents.Count -eq 1) "YTS response keeps an exact IMDb match and resource metadata"
Assert-Yts ($foundResult.firstFoundAt -eq $foundResult.checkedAt) "first YTS discovery uses the observation time"
$missingResult = ConvertFrom-YtsCatalogResponse -Payload $missingPayload -ImdbId "tt1002" -Now $now
Assert-Yts ($missingResult.status -eq "not_found" -and -not $missingResult.firstFoundAt) "empty successful YTS response confirms not found"
foreach ($badPayload in @(
    [pscustomobject]@{ status = "error"; data = [pscustomobject]@{ movie_count = 0 } },
    [pscustomobject]@{ status = "ok"; data = [pscustomobject]@{ movie_count = "0" } },
    [pscustomobject]@{ status = "ok"; data = [pscustomobject]@{ movie_count = 1; movies = @() } },
    [pscustomobject]@{ status = "ok"; data = [pscustomobject]@{ movie_count = 0; movies = @([pscustomobject]@{}) } },
    [pscustomobject]@{ status = "ok"; data = [pscustomobject]@{ movie_count = 1; movies = @([pscustomobject]@{ imdb_code = "tt9999" }) } }
)) {
    $rejected = $false
    try { ConvertFrom-YtsCatalogResponse -Payload $badPayload -ImdbId "tt1001" | Out-Null } catch { $rejected = $true }
    Assert-Yts $rejected "malformed or inexact YTS responses cannot establish absence"
}
$unsafeResource = [pscustomobject]@{ url = "https://yts.gg.example.test/torrent/download/$('b' * 40)"; quality = "1080p" }
Assert-Yts (@(ConvertTo-YtsTorrentMetadata -Torrents @($unsafeResource)).Count -eq 0) "YTS metadata rejects untrusted resource domains"

function New-YtsTestFilm {
    param([string]$Id, [string]$Status = "available_found", [string]$YtsStatus = "", [string]$CheckedAt = "")
    [pscustomobject]@{
        id = $Id; title = $Id; original_title = $Id; canonical_key = "imdb:$Id"; imdb_id = $Id
        notion_page_id = "page-$Id"; tracking_status = $Status
        yts_status = $YtsStatus; yts_imdb_id = $Id; yts_checked_at = $CheckedAt
        yts_first_found_at = ""; yts_torrents_json = "[]"
    }
}
$fresh = New-YtsTestFilm "tt1001"
$pending = New-YtsTestFilm "tt1002" "pending"
$missing = New-YtsTestFilm "tt1003" "available_found" "not_found" "2026-10-30T23:59:00+08:00"
$today = New-YtsTestFilm "tt1004" "available_found" "not_found" "2026-10-31T00:01:00+08:00"
$listed = New-YtsTestFilm "tt1005" "available_found" "found" "2020-01-01T00:00:00Z"
$changedIdentity = New-YtsTestFilm "tt1006" "available_found" "found" "2026-10-31T00:00:00Z"
$changedIdentity.yts_imdb_id = "tt9999"
$noImdb = New-YtsTestFilm ""
$candidates = @(Select-YtsCatalogCheckFilms -Films @($fresh, $pending, $missing, $today, $listed, $changedIdentity, $noImdb) -Now $now)
Assert-Yts ($candidates.Count -eq 3) "only available, valid, unchecked or previously missing films are due"
Assert-Yts (@($candidates | Where-Object { $_.imdb_id -eq "tt1003" }).Count -eq 1) "missing films are due again on the next Shanghai calendar day"
Assert-Yts (@($candidates | Where-Object { $_.imdb_id -eq "tt1006" }).Count -eq 1) "IMDb identity changes invalidate an old found result"

$eventFilm = New-YtsTestFilm "tt1010" "pending"
$orphanFilm = New-YtsTestFilm "tt1011"
$selection = [pscustomobject]@{ id = "selection"; film_relation_ids = @($eventFilm.notion_page_id) }
$event = [pscustomobject]@{ film_id = $eventFilm.id; film_title = $eventFilm.title }
$active = @(Select-YtsAvailableFilms -Films @($eventFilm, $orphanFilm) -Selections @($selection) -Events @($event))
Assert-Yts ($active.Count -eq 1 -and $active[0].tracking_status -eq "available_found") "YTS scope includes event-backed Available films and excludes inactive selections"

# Round-trip multi-span JSON through the actual Notion reader, without truncation.
$many = [pscustomobject]@{ imdbId = "tt1001"; status = "found"; checkedAt = $now.ToString("o"); firstFoundAt = $now.ToString("o"); torrents = @((1..25) | ForEach-Object { $resource }) }
$properties = ConvertTo-NotionYtsCatalogProperties -Result $many
Assert-Yts ($properties["YTS Torrents"].rich_text.Count -gt 1) "YTS resource JSON is split into Notion spans"
$pageProperties = [ordered]@{}
foreach ($name in $properties.Keys) {
    $value = $properties[$name]
    if ($value.ContainsKey("rich_text")) {
        $pageProperties[$name] = [pscustomobject]@{ type = "rich_text"; rich_text = @($value.rich_text | ForEach-Object { [pscustomobject]@{ plain_text = $_.text.content } }) }
    }
    elseif ($value.ContainsKey("select")) { $pageProperties[$name] = [pscustomobject]@{ type = "select"; select = [pscustomobject]$value.select } }
    else { $pageProperties[$name] = [pscustomobject]@{ type = "date"; date = [pscustomobject]$value.date } }
}
$pageProperties["IMDb ID"] = [pscustomobject]@{ type = "rich_text"; rich_text = @([pscustomobject]@{ plain_text = "tt1001" }) }
$notionFilm = ConvertFrom-NotionCanonicalFilmPage -Page ([pscustomobject]@{ id = "test-page"; properties = [pscustomobject]$pageProperties })
$roundTrip = Get-FilmYtsCatalogResult -Film $notionFilm
Assert-Yts ($roundTrip.torrents.Count -eq 25 -and $roundTrip.status -eq "found") "Notion YTS state round-trips through canonical film import"

& (Get-Module FestivalTracker) {
    param($Now, $FoundPayload, $MissingPayload, $NewFilm, $Assert)
    Set-Item -Path Function:New-YtsTestFilm -Value $NewFilm
    Set-Item -Path Function:Assert-Yts -Value $Assert
    $saved = @{}
    foreach ($name in @("Invoke-YtsCatalogRequest", "Invoke-NotionRequest", "Ensure-NotionYtsCatalogSchema")) { $saved[$name] = (Get-Command $name).ScriptBlock }
    try {
        $script:YtsTestCalls = New-Object System.Collections.Generic.List[string]
        $script:YtsTestWrites = New-Object System.Collections.Generic.List[object]
        $script:YtsTestMode = "success"
        $script:YtsFoundPayload = $FoundPayload
        $script:YtsMissingPayload = $MissingPayload
        function script:Ensure-NotionYtsCatalogSchema { param($DatabaseId) }
        function script:Invoke-YtsCatalogRequest {
            param($ImdbId)
            $script:YtsTestCalls.Add($ImdbId)
            if ($script:YtsTestMode -eq "429") {
                $exception = New-Object System.Exception("Too many requests")
                $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 429 })
                throw $exception
            }
            if ($script:YtsTestMode -eq "failure") { throw "Network unavailable" }
            if ($ImdbId -eq "tt1001") { return $script:YtsFoundPayload }
            return $script:YtsMissingPayload
        }
        function script:Invoke-NotionRequest {
            param($Method, $Path, $Body)
            $script:YtsTestWrites.Add([pscustomobject]@{ path = $Path; properties = $Body.properties })
        }
        $a = New-YtsTestFilm "tt1001"
        $duplicate = New-YtsTestFilm "tt1001"
        $duplicate.notion_page_id = "duplicate-page"
        $b = New-YtsTestFilm "tt1002"
        $stats = Sync-NotionYtsCatalog -Films @($a, $duplicate, $b) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        Assert-Yts ($stats.requests -eq 2 -and $stats.updated -eq 3) "YTS sync makes one request per IMDb ID and saves all canonical pages"
        Assert-Yts ($a.yts_status -eq "found" -and $b.yts_status -eq "not_found") "YTS sync persists positive and negative results"
        Assert-Yts (@($script:YtsTestWrites | Where-Object { @($_.properties.Keys | Where-Object { $_ -notlike "YTS *" }).Count -gt 0 }).Count -eq 0) "YTS sync patches only its own Notion fields"
        $again = Sync-NotionYtsCatalog -Films @($a, $duplicate, $b) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        Assert-Yts ($again.requests -eq 0) "repeat same-day runs perform no YTS checks"
        $tomorrow = Sync-NotionYtsCatalog -Films @($a, $duplicate, $b) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now.AddDays(1)
        Assert-Yts ($tomorrow.requests -eq 1 -and $tomorrow.found -eq 0) "the next day rechecks missing films and skips listed films"

        $old = $b.yts_checked_at
        $script:YtsTestMode = "failure"
        $failed = Sync-NotionYtsCatalog -Films @($b) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now.AddDays(2)
        Assert-Yts ($failed.failed -eq 1 -and $b.yts_checked_at -eq $old -and $b.yts_status -eq "not_found") "failed checks leave previous Notion state and timestamps unchanged"
        $duplicateFailure = Sync-NotionYtsCatalog -Films @((New-YtsTestFilm "tt1400"), (New-YtsTestFilm "tt1400")) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        Assert-Yts ($duplicateFailure.requests -eq 1 -and $duplicateFailure.updated -eq 0) "failed duplicate identities are also checked only once per run"
        $script:YtsTestMode = "429"
        $paused = Sync-NotionYtsCatalog -Films @((New-YtsTestFilm "tt1100"), (New-YtsTestFilm "tt1101")) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        Assert-Yts ($paused.requests -eq 1 -and $paused.stopped -eq "http_429" -and $paused.updated -eq 0) "a YTS rate limit stops all remaining requests in the run"
        $script:YtsTestMode = "failure"
        $paused = Sync-NotionYtsCatalog -Films @((1..5 | ForEach-Object { New-YtsTestFilm "tt120$_" })) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        Assert-Yts ($paused.requests -eq 3 -and $paused.stopped -eq "consecutive_failures") "three consecutive YTS failures stop the run"
        $dry = Sync-NotionYtsCatalog -Films @((New-YtsTestFilm "tt1300")) -DatabaseId "test-db" -DryRun -Now $Now
        Assert-Yts ($dry.requests -eq 0 -and $dry.updated -eq 0 -and $dry.candidates -eq 1) "YTS dry run only reports candidates"
    }
    finally {
        foreach ($name in $saved.Keys) { Set-Item -Path "Function:script:$name" -Value $saved[$name] }
        Remove-Variable -Scope Script -Name YtsTestCalls, YtsTestWrites, YtsTestMode, YtsFoundPayload, YtsMissingPayload -ErrorAction SilentlyContinue
    }
} $now $foundPayload $missingPayload (Get-Command New-YtsTestFilm).ScriptBlock (Get-Command Assert-Yts).ScriptBlock
