$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1") -Force

function Assert-Yts {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message" -ForegroundColor Green
}

$now = [datetimeoffset]"2026-10-31T01:00:00Z"
$resource = [pscustomobject]@{ url = "https://yts.pw/torrent/download/$('a' * 40)"; quality = "1080p"; video_codec = "x265"; type = "bluray"; bit_depth = "10"; audio_channels = "5.1"; size_bytes = 2147483648 }
$foundPayload = [pscustomobject]@{ status = "ok"; data = [pscustomobject]@{ movie_count = 1; movies = @([pscustomobject]@{ imdb_code = "tt1001"; torrents = @($resource) }) } }
$missingPayload = [pscustomobject]@{ status = "ok"; data = [pscustomobject]@{ movie_count = 0 } }
$foundResult = ConvertFrom-YtsCatalogResponse -Payload $foundPayload -ImdbId "tt1001" -Now $now
Assert-Yts ($foundResult.status -eq "found" -and $foundResult.torrents.Count -eq 1 -and $foundResult.torrents[0].url -eq $resource.url) "YTS response keeps an exact IMDb match and the configured yts.pw download"
Assert-Yts ($foundResult.torrents[0].hash -eq ('a' * 40)) "legacy download addresses supply their torrent hash"
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
$movedResource = [pscustomobject]@{ url = "https://new-yts.example.org/torrent/download/$('a' * 40)"; hash = 'A' * 40; quality = "1080p" }
$movedMovie = [pscustomobject]@{ imdb_code = "tt1001"; url = "https://new-yts.example.org/movies/example-2026"; torrents = @($movedResource, $unsafeResource) }
$movedPayload = [pscustomobject]@{ status = "ok"; data = [pscustomobject]@{ movie_count = 1; movies = @($movedMovie) } }
$movedResult = ConvertFrom-YtsCatalogResponse -Payload $movedPayload -ImdbId "tt1001" -Now $now
Assert-Yts ($movedResult.torrents.Count -eq 1 -and $movedResult.torrents[0].apiHost -eq "new-yts.example.org") "fresh YTS metadata accepts a new movie host with a matching reported hash"
$movedResource.hash = 'b' * 40
$mismatch = ConvertFrom-YtsCatalogResponse -Payload $movedPayload -ImdbId "tt1001" -Now $now
Assert-Yts ($mismatch.torrents.Count -eq 0) "a new host cannot authorize a download with a mismatched hash"
$movedResource.hash = 'A' * 40

function New-YtsTestFilm {
    param([string]$Id, [string]$Status = "available_found", [string]$YtsStatus = "", [string]$CheckedAt = "", [object]$PremiereYear = 2026)
    [pscustomobject]@{
        id = $Id; title = $Id; original_title = $Id; canonical_key = "imdb:$Id"; imdb_id = $Id
        notion_page_id = "page-$Id"; tracking_status = $Status
        premiere_year = $PremiereYear
        yts_status = $YtsStatus; yts_imdb_id = $Id; yts_checked_at = $CheckedAt
        yts_first_found_at = ""; yts_torrents_json = "[]"
    }
}
$fresh = New-YtsTestFilm "tt1001"
$pending = New-YtsTestFilm "tt1002" "pending"
$missing = New-YtsTestFilm "tt1003" "available_found" "not_found" "2026-10-30T23:59:00+08:00"
$today = New-YtsTestFilm "tt1004" "available_found" "not_found" "2026-10-31T00:01:00+08:00"
$listed = New-YtsTestFilm "tt1005" "available_found" "found" $now.AddDays(-6).ToString("o")
$listed.yts_torrents_json = ConvertTo-Json -InputObject @($resource) -Compress
$changedIdentity = New-YtsTestFilm "tt1006" "available_found" "found" "2026-10-31T00:00:00Z"
$changedIdentity.yts_imdb_id = "tt9999"
$noImdb = New-YtsTestFilm ""
$candidates = @(Select-YtsCatalogCheckFilms -Films @($fresh, $pending, $missing, $today, $listed, $changedIdentity, $noImdb) -Now $now)
Assert-Yts ($candidates.Count -eq 4) "valid unchecked or missing films are due regardless of historical availability"
Assert-Yts (@($candidates | Where-Object { $_.imdb_id -eq "tt1002" }).Count -eq 1) "pending films receive their first YTS check"
Assert-Yts (@($candidates | Where-Object { $_.imdb_id -eq "tt1003" }).Count -eq 1) "missing films are due again on the next Shanghai calendar day"
Assert-Yts (@($candidates | Where-Object { $_.imdb_id -eq "tt1006" }).Count -eq 1) "IMDb identity changes invalidate an old found result"
Assert-Yts (@(Select-YtsCatalogCheckFilms -Films @($listed) -Now $now.AddDays(1)).Count -eq 1) "found films with links refresh after seven Shanghai calendar days"
$noLink = New-YtsTestFilm "tt1007" "pending" "found" "2026-10-30T23:59:00+08:00"
Assert-Yts (@(Select-YtsCatalogCheckFilms -Films @($noLink) -Now $now.AddDays(-1)).Count -eq 0) "a fresh listing with no usable torrent waits until the next check is due"
Assert-Yts (@(Select-YtsCatalogCheckFilms -Films @($noLink) -Now $now).Count -eq 1) "a recent listing without a usable torrent is due again the next day"

foreach ($year in @(2025, 2026)) {
    $recent = New-YtsTestFilm "tt1020" "available_found" "not_found" "2026-10-30T23:59:00+08:00" $year
    Assert-Yts (@(Select-YtsCatalogCheckFilms -Films @($recent) -Now $now).Count -eq 1) "current and previous premiere years receive daily rechecks ($year)"
}
$weekly = New-YtsTestFilm "tt1021" "available_found" "not_found" "2026-10-24T23:59:00+08:00" 2023
Assert-Yts (@(Select-YtsCatalogCheckFilms -Films @($weekly) -Now $now.AddDays(-1)).Count -eq 0) "older films wait until seven Shanghai calendar days have passed"
Assert-Yts (@(Select-YtsCatalogCheckFilms -Films @($weekly) -Now $now).Count -eq 1) "older films are due exactly on the seventh Shanghai calendar day"
$newOldFilm = New-YtsTestFilm "tt1022" -PremiereYear 2023
Assert-Yts (@(Select-YtsCatalogCheckFilms -Films @($newOldFilm) -Now $now).Count -eq 1) "newly eligible old films receive an initial check without waiting a week"
$yearBoundary = New-YtsTestFilm "tt1023" "available_found" "not_found" "2026-12-30T12:00:00+08:00" 2025
Assert-Yts (@(Select-YtsCatalogCheckFilms -Films @($yearBoundary) -Now ([datetimeoffset]"2026-12-31T15:59:00Z")).Count -eq 1) "last year's films remain daily until Shanghai New Year"
Assert-Yts (@(Select-YtsCatalogCheckFilms -Films @($yearBoundary) -Now ([datetimeoffset]"2026-12-31T16:00:00Z")).Count -eq 0) "the recent-year window rolls over at Shanghai midnight"
$legacyYear = New-YtsTestFilm "tt1024" "available_found" "not_found" "2026-10-30T12:00:00+08:00" $null
Set-RecordProperty -Record $legacyYear -Name "film_year" -Value 2023
Assert-Yts (@(Select-YtsCatalogCheckFilms -Films @($legacyYear) -Now $now).Count -eq 0) "legacy film year supplies the premiere-year fallback"
$legacyYear.premiere_year = 2026
Assert-Yts (@(Select-YtsCatalogCheckFilms -Films @($legacyYear) -Now $now).Count -eq 1) "explicit premiere year takes precedence over legacy film year"
foreach ($year in @($null, 2027)) {
    $uncertainYear = New-YtsTestFilm "tt1025" "available_found" "not_found" "2026-10-30T12:00:00+08:00" $year
    Assert-Yts (@(Select-YtsCatalogCheckFilms -Films @($uncertainYear) -Now $now).Count -eq 1) "unknown or future premiere years retain daily checks"
}

$eventFilm = New-YtsTestFilm "tt1010" "pending"
$orphanFilm = New-YtsTestFilm "tt1011"
$selection = [pscustomobject]@{ id = "selection"; film_relation_ids = @($eventFilm.notion_page_id) }
$event = [pscustomobject]@{ film_id = $eventFilm.id; film_title = $eventFilm.title }
$active = @(Select-CanonicalFilmsWithActiveSelections -Films @($eventFilm, $orphanFilm) -Selections @($selection))
Assert-Yts ($active.Count -eq 1 -and $active[0].tracking_status -eq "pending") "YTS scope includes pending films with active selections without rewriting historical availability"

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
$datePage = [pscustomobject]@{ properties = [pscustomobject]@{
    "YTS First Found At" = [pscustomobject]@{ type = "date"; date = [pscustomobject]@{ start = [datetime]::SpecifyKind([datetime]"2026-10-31T13:12:00", [DateTimeKind]::Utc) } }
} }
$isoDate = Get-NotionTextProperty -Page $datePage -Name "YTS First Found At"
Assert-Yts ($isoDate -eq "2026-10-31T13:12:00.0000000Z") "typed Notion dates remain ISO timestamps instead of locale-formatted strings"
$datePage.properties.'YTS First Found At'.date.start = [datetimeoffset]"2026-10-31T21:12:00+08:00"
$isoOffsetDate = Get-NotionTextProperty -Page $datePage -Name "YTS First Found At"
Assert-Yts ($isoOffsetDate -eq "2026-10-31T21:12:00.0000000+08:00") "typed Notion dates preserve explicit offsets"
$dateFilm = New-YtsTestFilm "tt1700" "pending" "found" "2026-10-31T13:12:00Z"
$dateFilm.yts_first_found_at = $isoOffsetDate
$dateResult = Get-FilmYtsCatalogResult -Film $dateFilm
Assert-Yts ($dateResult.firstFoundAt -eq "2026-10-31T13:12:00.0000000+00:00") "shared YTS discovery timestamps normalize to UTC before reuse or export"
$dateProperties = ConvertTo-NotionYtsCatalogProperties -Result $dateResult
Assert-Yts ($dateProperties.'YTS First Found At'.date.start -eq $dateResult.firstFoundAt) "reused YTS discovery dates are valid ISO values for Notion writes"

& (Get-Module FestivalTracker) {
    param($Now, $FoundPayload, $MissingPayload, $MovedPayload, $NewFilm, $Assert)
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
            if ($script:YtsTestMode -in @("403", "429")) {
                $exception = New-Object System.Exception("Too many requests")
                $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = [int]$script:YtsTestMode })
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
        $a = New-YtsTestFilm "tt1001" "pending"
        $duplicate = New-YtsTestFilm "tt1001"
        $duplicate.notion_page_id = "duplicate-page"
        $b = New-YtsTestFilm "tt1002"
        $stats = Sync-NotionYtsCatalog -Films @($a, $duplicate, $b) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        Assert-Yts ($stats.requests -eq 2 -and $stats.updated -eq 3) "YTS sync makes one request per IMDb ID and saves all canonical pages"
        Assert-Yts ($a.yts_status -eq "found" -and $b.yts_status -eq "not_found") "YTS sync persists positive and negative results"
        Assert-Yts ($a.tracking_status -eq "pending") "a confirmed YTS listing never rewrites historical legal-availability status"
        Assert-Yts (@($script:YtsTestWrites | Where-Object { @($_.properties.Keys | Where-Object { $_ -notlike "YTS *" }).Count -gt 0 }).Count -eq 0) "YTS sync patches only its own Notion fields"
        $again = Sync-NotionYtsCatalog -Films @($a, $duplicate, $b) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        Assert-Yts ($again.requests -eq 0) "repeat same-day runs perform no YTS checks"
        $tomorrow = Sync-NotionYtsCatalog -Films @($a, $duplicate, $b) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now.AddDays(1)
        Assert-Yts ($tomorrow.requests -eq 1 -and $tomorrow.found -eq 0) "the next day rechecks missing films and skips listed films"

        $firstSeen = $Now.AddDays(-3).ToString("o")
        $withoutLink = New-YtsTestFilm "tt1001" "pending" "found" $firstSeen
        $withoutLink.yts_first_found_at = $firstSeen
        $recovered = Sync-NotionYtsCatalog -Films @($withoutLink) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        Assert-Yts ($recovered.requests -eq 1 -and (Get-FilmYtsCatalogResult -Film $withoutLink).torrents.Count -eq 1 -and $withoutLink.yts_first_found_at -eq $firstSeen) "YTS sync repopulates missing links and keeps the original discovery time"

        $script:YtsFoundPayload = $MovedPayload
        $stableListing = New-YtsTestFilm "tt1001" "pending" "found" $Now.AddDays(-7).ToString("o")
        $stableListing.yts_first_found_at = $stableListing.yts_checked_at
        $stableListing.yts_torrents_json = '[{"url":"https://yts.gg/torrent/download/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","quality":"1080p"},{"url":"https://yts.gg/torrent/download/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","quality":"720p"}]'
        $refreshed = Sync-NotionYtsCatalog -Films @($stableListing) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        $stableResult = Get-FilmYtsCatalogResult -Film $stableListing
        Assert-Yts ($refreshed.requests -eq 1 -and $stableResult.torrents.Count -eq 2 -and
            $stableResult.torrents[0].url -eq $MovedPayload.data.movies[0].torrents[0].url -and
            $stableResult.torrents[0].hash -eq ('a' * 40) -and $stableResult.torrents[1].hash -eq ('b' * 40) -and
            $stableResult.firstFoundAt -eq $Now.AddDays(-7).ToString("o")) "domain refresh replaces a same-hash address and preserves older versions and discovery time"
        $script:YtsFoundPayload = $FoundPayload

        $blankDuplicate = New-YtsTestFilm "tt1001" "pending" "found" $firstSeen
        $blankDuplicate.yts_first_found_at = $firstSeen
        $blankDuplicate.notion_page_id = "blank-duplicate-page"
        $copied = Sync-NotionYtsCatalog -Films @($withoutLink, $blankDuplicate) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        Assert-Yts ($copied.requests -eq 0 -and $copied.updated -eq 1 -and $blankDuplicate.yts_torrents_json -eq $withoutLink.yts_torrents_json) "an empty duplicate can reuse an existing usable listing"

        $onceListed = New-YtsTestFilm "tt1002" "pending" "found" $firstSeen
        $onceListed.yts_first_found_at = $firstSeen
        $nowAbsent = Sync-NotionYtsCatalog -Films @($onceListed) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        Assert-Yts ($nowAbsent.requests -eq 1 -and $onceListed.yts_status -eq "found" -and $onceListed.yts_first_found_at -eq $firstSeen -and [datetimeoffset]$onceListed.yts_checked_at -ge $Now) "a successful negative recheck advances the check date and keeps the confirmed listing"

        $old = $b.yts_checked_at
        $script:YtsTestMode = "failure"
        $failed = Sync-NotionYtsCatalog -Films @($b) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now.AddDays(2)
        Assert-Yts ($failed.failed -eq 1 -and $b.yts_checked_at -eq $old -and $b.yts_status -eq "not_found") "failed checks leave previous Notion state and timestamps unchanged"

        $script:YtsTestMode = "success"
        $oldFilm = New-YtsTestFilm "tt1500" -PremiereYear 2023
        $initialOld = Sync-NotionYtsCatalog -Films @($oldFilm) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        Assert-Yts ($initialOld.requests -eq 1 -and $oldFilm.yts_status -eq "not_found") "a new old film is checked immediately"
        $earlyOld = Sync-NotionYtsCatalog -Films @($oldFilm) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now.AddDays(1)
        Assert-Yts ($earlyOld.requests -eq 0) "an initially missing old film starts weekly checks immediately without a daily grace period"
        $lastSuccess = $oldFilm.yts_checked_at
        $script:YtsTestMode = "failure"
        $weeklyFailure = Sync-NotionYtsCatalog -Films @($oldFilm) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now.AddDays(7)
        Assert-Yts ($weeklyFailure.requests -eq 1 -and $weeklyFailure.updated -eq 0 -and $oldFilm.yts_checked_at -eq $lastSuccess) "a failed weekly check preserves its last-success date"
        $script:YtsTestMode = "success"
        $weeklyRetry = Sync-NotionYtsCatalog -Films @($oldFilm) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now.AddDays(8)
        Assert-Yts ($weeklyRetry.requests -eq 1 -and $weeklyRetry.not_found -eq 1) "a failed weekly check is retried in the next daily task"
        $beforeNextWeek = Sync-NotionYtsCatalog -Films @($oldFilm) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now.AddDays(14)
        Assert-Yts ($beforeNextWeek.requests -eq 0) "weekly cadence resets from the successful retry rather than the failed attempt"
        $nextWeek = Sync-NotionYtsCatalog -Films @($oldFilm) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now.AddDays(15)
        Assert-Yts ($nextWeek.requests -eq 1) "the next weekly check follows seven days after the successful retry"

        $staleDuplicate = New-YtsTestFilm "tt1600" "available_found" "not_found" $Now.AddDays(-10).ToString("o") 2023
        $freshDuplicate = New-YtsTestFilm "tt1600" "available_found" "not_found" $Now.AddDays(-3).ToString("o") 2023
        $freshDuplicate.notion_page_id = "fresh-duplicate-page"
        $reuse = Sync-NotionYtsCatalog -Films @($staleDuplicate, $freshDuplicate) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        Assert-Yts ($reuse.requests -eq 0 -and $reuse.updated -eq 1 -and $staleDuplicate.yts_checked_at -eq $freshDuplicate.yts_checked_at) "weekly duplicate pages reuse the latest still-fresh shared result"
        $recentDuplicate = New-YtsTestFilm "tt1600" "available_found" "not_found" $Now.AddDays(-10).ToString("o") 2026
        $daily = Sync-NotionYtsCatalog -Films @($recentDuplicate, $freshDuplicate) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        Assert-Yts ($daily.requests -eq 1) "a weekly cached result cannot suppress a due daily check for the same IMDb identity"

        $script:YtsTestMode = "failure"
        $duplicateFailure = Sync-NotionYtsCatalog -Films @((New-YtsTestFilm "tt1400"), (New-YtsTestFilm "tt1400")) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        Assert-Yts ($duplicateFailure.requests -eq 1 -and $duplicateFailure.updated -eq 0) "failed duplicate identities are also checked only once per run"
        $script:YtsTestMode = "429"
        $paused = Sync-NotionYtsCatalog -Films @((New-YtsTestFilm "tt1100"), (New-YtsTestFilm "tt1101")) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        Assert-Yts ($paused.requests -eq 1 -and $paused.stopped -eq "http_429" -and $paused.updated -eq 0) "a YTS rate limit stops all remaining requests in the run"
        $script:YtsTestMode = "403"
        $denied = Sync-NotionYtsCatalog -Films @((New-YtsTestFilm "tt1100"), (New-YtsTestFilm "tt1101")) -DatabaseId "test-db" -MinIntervalMs 0 -Now $Now
        Assert-Yts ($denied.requests -eq 1 -and $denied.stopped -eq "http_403") "an access rejection also stops all remaining requests in the run"
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
} $now $foundPayload $missingPayload $movedPayload (Get-Command New-YtsTestFilm).ScriptBlock (Get-Command Assert-Yts).ScriptBlock
