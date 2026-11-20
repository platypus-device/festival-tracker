# YTS is the tracked catalog. Historical legal-availability records are left untouched.
$Script:YtsDownloadHosts = [string[]](Get-Content -LiteralPath (Join-Path $PSScriptRoot "../web/data/yts-download-hosts.json") -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)

function ConvertTo-YtsTorrentMetadata {
    param([object[]]$Torrents = @(), [string]$ApiHost, [switch]$FromStoredResult)

    foreach ($torrent in $Torrents) {
        $url = [string](Get-ObjectProperty $torrent "url" "")
        $uri = $null
        if (-not [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) { continue }
        if ($uri.Scheme -ne "https" -or -not $uri.IsDefaultPort -or $uri.UserInfo -or
            $uri.HostNameType -ne [UriHostNameType]::Dns -or -not $uri.Host.Contains(".") -or
            $uri.AbsolutePath -notmatch '^/torrent/download/([a-f0-9]{40})$') { continue }
        $hash = $Matches[1].ToLowerInvariant()
        $reportedHash = [string](Get-ObjectProperty $torrent "hash" "")
        if ($reportedHash -and $reportedHash -ne $hash) { continue }
        $verifiedHost = if ($FromStoredResult) { Get-ObjectProperty $torrent "apiHost" } else { $ApiHost }
        $verifiedByApi = $reportedHash -eq $hash -and $uri.Host -eq $verifiedHost
        if ($uri.Host -notin $Script:YtsDownloadHosts -and -not $verifiedByApi) { continue }
        $quality = [string](Get-ObjectProperty $torrent "quality" "")
        if ($quality -notmatch '^([0-9]{3,4})p(?:\b|$)' -or [int]$Matches[1] -eq 0) { continue }

        $metadata = [ordered]@{ url = $uri.AbsoluteUri; hash = $hash; quality = $quality }
        if ($verifiedByApi) { $metadata.apiHost = $uri.Host }
        foreach ($name in @("video_codec", "type", "bit_depth", "audio_channels", "size_bytes", "size")) {
            $value = Get-ObjectProperty $torrent $name
            if ($null -ne $value -and ([string]$value).Length -le 64) { $metadata[$name] = $value }
        }
        [pscustomobject]$metadata
    }
}

function Merge-YtsTorrentMetadata {
    param([object[]]$Previous = @(), [object[]]$Current = @())

    # A bookmarked hash keeps its last known address until the same version is observed again.
    $byHash = [ordered]@{}
    foreach ($torrent in ($Previous + $Current)) {
        if ($torrent.hash) { $byHash[$torrent.hash] = $torrent }
    }
    $byHash.Values
}

function ConvertFrom-YtsCatalogResponse {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][ValidatePattern('^tt\d+$')][string]$ImdbId,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )

    $data = Get-ObjectProperty $Payload "data"
    $count = Get-ObjectProperty $data "movie_count"
    $movies = $data.movies
    if ($null -eq $movies) { $movies = @() }
    if ((Get-ObjectProperty $Payload "status") -cne "ok" -or
        ($count -isnot [int] -and $count -isnot [long]) -or $count -lt 0 -or
        $movies -isnot [array] -or ($count -eq 0 -and $movies.Count -gt 0) -or
        ($count -gt 0 -and $movies.Count -eq 0)) {
        throw "Unexpected YTS response for $ImdbId."
    }
    $movie = @($movies | Where-Object { (Get-ObjectProperty $_ "imdb_code") -ceq $ImdbId } | Select-Object -First 1)
    if ($count -gt 0 -and $movie.Count -eq 0) {
        throw "YTS returned no exact IMDb match for $ImdbId."
    }
    $torrents = @()
    if ($movie.Count -gt 0) {
        $resources = $movie[0].torrents
        $movieUri = $null
        $apiHost = ""
        if ([uri]::TryCreate([string]$movie[0].url, [UriKind]::Absolute, [ref]$movieUri) -and
            $movieUri.Scheme -eq "https" -and $movieUri.IsDefaultPort -and -not $movieUri.UserInfo -and
            $movieUri.HostNameType -eq [UriHostNameType]::Dns -and $movieUri.Host.Contains(".") -and
            $movieUri.AbsolutePath -match '^/movies/[a-z0-9-]+/?$') {
            $apiHost = $movieUri.Host
        }
        if ($resources -is [array]) { $torrents = @(ConvertTo-YtsTorrentMetadata -Torrents $resources -ApiHost $apiHost) }
    }
    return [pscustomobject]@{
        imdbId = $ImdbId
        status = if ($movie.Count -gt 0) { "found" } else { "not_found" }
        checkedAt = $Now.ToUniversalTime().ToString("o")
        firstFoundAt = if ($movie.Count -gt 0) { $Now.ToUniversalTime().ToString("o") } else { "" }
        torrents = @($torrents)
    }
}

function Get-FilmYtsCatalogResult {
    param([Parameter(Mandatory = $true)][object]$Film)

    $imdbId = ([string](Get-ObjectProperty $Film "imdb_id" "")).Trim().ToLowerInvariant()
    $status = [string](Get-ObjectProperty $Film "yts_status" "")
    $checkedAt = [string](Get-ObjectProperty $Film "yts_checked_at" "")
    $date = [datetimeoffset]::MinValue
    if ($imdbId -notmatch '^tt\d+$' -or $imdbId -cne [string](Get-ObjectProperty $Film "yts_imdb_id" "") -or
        $status -notin @("found", "not_found") -or -not [datetimeoffset]::TryParse($checkedAt, [ref]$date)) { return $null }

    $torrents = @()
    try {
        $resources = ConvertFrom-Json -InputObject ([string](Get-ObjectProperty $Film "yts_torrents_json" "[]")) -ErrorAction Stop
        $torrents = @(ConvertTo-YtsTorrentMetadata -Torrents @($resources) -FromStoredResult)
    }
    catch { } # A damaged resource field must not hide a confirmed catalog result.
    $firstFound = [datetimeoffset]::MinValue
    $hasFirstFound = [datetimeoffset]::TryParse([string](Get-ObjectProperty $Film "yts_first_found_at" ""), [ref]$firstFound)
    return [pscustomobject]@{
        imdbId = $imdbId
        status = $status
        checkedAt = $date.ToUniversalTime().ToString("o")
        firstFoundAt = if ($hasFirstFound) { $firstFound.ToUniversalTime().ToString("o") } else { "" }
        torrents = @($torrents)
    }
}

function Get-YtsCatalogRecheckIntervalDays {
    param([Parameter(Mandatory = $true)][object]$Film, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)

    $currentYear = $Now.ToOffset([timespan]::FromHours(8)).Year
    $premiereYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "premiere_year")
    if ($null -eq $premiereYear) { $premiereYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "film_year") }
    # Missing or future year metadata should not silently reduce checks.
    if ($null -ne $premiereYear -and $premiereYear -ge 1000 -and $premiereYear -lt ($currentYear - 1)) { return 7 }
    return 1
}

function Test-YtsCatalogResultDue {
    param(
        [Parameter(Mandatory = $true)][object]$Film,
        [AllowNull()][object]$Result,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )

    if ($null -eq $Result) { return $true }
    # Only successful checks advance this date; an overdue failure stays due next run.
    $today = $Now.ToOffset([timespan]::FromHours(8)).Date
    $lastSuccess = ([datetimeoffset]$Result.checkedAt).ToOffset([timespan]::FromHours(8)).Date
    $interval = if ($Result.status -eq "found" -and $Result.torrents.Count -gt 0) { 7 } else {
        Get-YtsCatalogRecheckIntervalDays -Film $Film -Now $Now
    }
    return $lastSuccess.AddDays($interval) -le $today
}

function Select-YtsCatalogCheckFilms {
    param([object[]]$Films = @(), [datetimeoffset]$Now = [datetimeoffset]::UtcNow)

    return @($Films | Where-Object {
        if (([string](Get-ObjectProperty $_ "imdb_id" "")).Trim() -notmatch '^tt\d+$') { return $false }
        $result = Get-FilmYtsCatalogResult -Film $_
        return Test-YtsCatalogResultDue -Film $_ -Result $result -Now $Now
    } | Sort-Object { [string](Get-ObjectProperty $_ "yts_checked_at" "") }, { [string](Get-ObjectProperty $_ "imdb_id" "") })
}

function Ensure-NotionYtsCatalogSchema {
    param([Parameter(Mandatory = $true)][string]$DatabaseId)

    Update-NotionDatabaseSchemaProperties -DatabaseId $DatabaseId -DatabaseLabel "Canonical Films YTS" -DesiredProperties @{
        "YTS Status" = @{ select = @{ options = @(
            @{ name = "found"; color = "green" }, @{ name = "not_found"; color = "gray" }
        ) } }
        "YTS IMDb ID" = @{ rich_text = @{} }
        "YTS Checked At" = @{ date = @{} }
        "YTS First Found At" = @{ date = @{} }
        "YTS Torrents" = @{ rich_text = @{} }
    } | Out-Null
}

function ConvertTo-NotionYtsCatalogProperties {
    param([Parameter(Mandatory = $true)][object]$Result)

    # Split JSON into Notion text spans instead of truncating resource metadata.
    $json = ConvertTo-Json -InputObject @($Result.torrents) -Depth 8 -Compress
    $spans = @()
    for ($offset = 0; $offset -lt $json.Length; $offset += 1900) {
        $spans += @{ text = @{ content = $json.Substring($offset, [Math]::Min(1900, $json.Length - $offset)) } }
    }
    if ($spans.Count -gt 100) { throw "YTS resource metadata exceeds the Notion rich-text limit." }
    return @{
        "YTS Status" = @{ select = @{ name = $Result.status } }
        "YTS IMDb ID" = New-RichTextProperty $Result.imdbId
        "YTS Checked At" = @{ date = @{ start = $Result.checkedAt } }
        "YTS First Found At" = @{ date = $(if ($Result.firstFoundAt) { @{ start = $Result.firstFoundAt } } else { $null }) }
        "YTS Torrents" = @{ rich_text = @($spans) }
    }
}

function Invoke-YtsCatalogRequest {
    param([Parameter(Mandatory = $true)][ValidatePattern('^tt\d+$')][string]$ImdbId)

    $uri = "https://movies-api.accel.li/api/v2/list_movies.json?query_term=$ImdbId&limit=50"
    return Invoke-RestMethod -Uri $uri -Headers @{ "User-Agent" = $Script:UserAgent; "Accept" = "application/json" } -TimeoutSec 20 -ErrorAction Stop
}

function Sync-NotionYtsCatalog {
    param(
        [object[]]$Films = @(),
        [Parameter(Mandatory = $true)][string]$DatabaseId,
        [ValidateRange(0, 60000)][int]$MinIntervalMs = 3000,
        [ValidateRange(1, 120)][int]$MaxDurationMinutes = 25,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow,
        [switch]$DryRun
    )

    $candidates = @(Select-YtsCatalogCheckFilms -Films $Films -Now $Now)
    $stats = [pscustomobject]@{ candidates = $candidates.Count; requests = 0; updated = 0; found = 0; not_found = 0; failed = 0; deferred = 0; stopped = "" }
    if ($DryRun) { $stats.deferred = $candidates.Count; return $stats }
    Ensure-NotionYtsCatalogSchema -DatabaseId $DatabaseId
    $resultsByImdb = @{}
    $firstFoundByImdb = @{}
    foreach ($film in $Films) {
        $result = Get-FilmYtsCatalogResult -Film $film
        if ($null -eq $result) { continue }
        $imdbId = $result.imdbId
        $cached = $resultsByImdb[$imdbId]
        $hasLinks = $result.torrents.Count -gt 0
        $cachedHasLinks = $cached.torrents.Count -gt 0
        $preferIncoming = $null -eq $cached -or ($result.status -eq "found" -and $cached.status -ne "found") -or
            ($result.status -eq $cached.status -and (($hasLinks -and -not $cachedHasLinks) -or
                ($hasLinks -eq $cachedHasLinks -and [datetimeoffset]$result.checkedAt -gt [datetimeoffset]$cached.checkedAt)))
        if ($preferIncoming) { $resultsByImdb[$imdbId] = $result }
        if ($result.status -eq "found" -and $cached.status -eq "found") {
            $selected = $resultsByImdb[$imdbId]
            $other = if ($preferIncoming) { $cached } else { $result }
            $selected.torrents = @(Merge-YtsTorrentMetadata -Previous $other.torrents -Current $selected.torrents)
        }
        $firstFoundAt = $firstFoundByImdb[$imdbId]
        if ($result.firstFoundAt -and (-not $firstFoundAt -or [datetimeoffset]$result.firstFoundAt -lt [datetimeoffset]$firstFoundAt)) {
            $firstFoundByImdb[$imdbId] = $result.firstFoundAt
        }
    }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $lastRequestAt = -$MinIntervalMs
    $attemptedImdb = @{}
    $failures = 0
    foreach ($film in $candidates) {
        if ($clock.Elapsed.TotalMinutes -ge $MaxDurationMinutes) { $stats.stopped = "time_budget"; break }
        $pageId = [string](Get-ObjectProperty $film "notion_page_id" "")
        if ([string]::IsNullOrWhiteSpace($pageId)) { throw "YTS sync requires a canonical Notion page ID for every candidate." }
        $imdbId = ([string]$film.imdb_id).Trim().ToLowerInvariant()
        $cached = $resultsByImdb[$imdbId]
        $result = $cached
        if (Test-YtsCatalogResultDue -Film $film -Result $result -Now $Now) { $result = $null }
        if ($null -eq $result) {
            if ($attemptedImdb.ContainsKey($imdbId)) { continue }
            $attemptedImdb[$imdbId] = $true
            $delay = $MinIntervalMs - ($clock.ElapsedMilliseconds - $lastRequestAt)
            if ($delay -gt 0) { Start-Sleep -Milliseconds ([int]$delay) }
            $lastRequestAt = $clock.ElapsedMilliseconds
            $stats.requests++
            try {
                $payload = Invoke-YtsCatalogRequest -ImdbId $imdbId
                $result = ConvertFrom-YtsCatalogResponse -Payload $payload -ImdbId $imdbId -Now ($Now.AddMilliseconds($clock.ElapsedMilliseconds))
                if ($cached.status -eq "found") {
                    $result.status = "found"
                    $result.torrents = @(Merge-YtsTorrentMetadata -Previous $cached.torrents -Current $result.torrents)
                }
                $resultsByImdb[$imdbId] = $result
                $failures = 0
            }
            catch {
                $stats.failed++
                $failures++
                $response = $_.Exception.Response
                $status = if ($null -ne $response -and $null -ne $response.StatusCode) { [int]$response.StatusCode } else { 0 }
                Write-Warning "YTS check failed for ${imdbId}: $($_.Exception.Message)"
                # Do not make another request in this run after a rate limit or access block.
                if ($status -in @(403, 429) -or $failures -ge 3) {
                    $stats.stopped = if ($status -in @(403, 429)) { "http_$status" } else { "consecutive_failures" }
                    break
                }
                continue
            }
        }
        if ($firstFoundByImdb[$imdbId]) { $result.firstFoundAt = $firstFoundByImdb[$imdbId] }
        $properties = ConvertTo-NotionYtsCatalogProperties -Result $result
        # Persist each result immediately; a later API failure cannot lose earlier work.
        Invoke-NotionRequest -Method "PATCH" -Path "/v1/pages/$pageId" -Body @{ properties = $properties } | Out-Null
        Set-RecordProperty -Record $film -Name "yts_status" -Value $result.status
        Set-RecordProperty -Record $film -Name "yts_imdb_id" -Value $result.imdbId
        Set-RecordProperty -Record $film -Name "yts_checked_at" -Value $result.checkedAt
        Set-RecordProperty -Record $film -Name "yts_first_found_at" -Value $result.firstFoundAt
        Set-RecordProperty -Record $film -Name "yts_torrents_json" -Value (ConvertTo-Json -InputObject @($result.torrents) -Depth 8 -Compress)
        $stats.updated++
        if ($result.status -eq "found") { $stats.found++ } else { $stats.not_found++ }
        Write-Host "YTS $($stats.updated)/$($stats.candidates): $imdbId $($result.status)"
    }
    $stats.deferred = $stats.candidates - $stats.updated
    return $stats
}
