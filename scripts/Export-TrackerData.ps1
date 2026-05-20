param(
    [string]$OutputPath = (Join-Path (Get-Location) "web\data\tracker-data.json"),
    [switch]$UseNotion,
    [string]$StateDir = (Join-Path (Get-Location) ".tracker")
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1"
Import-Module $modulePath -Force

function ConvertTo-EventRecord {
    param([Parameter(Mandatory = $true)][object]$Page)

    $typesProperty = Get-ObjectProperty $Page.properties "Availability Types"
    $types = @()
    if ($null -ne $typesProperty) {
        $types = @($typesProperty.multi_select | ForEach-Object { $_.name } | Where-Object { $_ })
    }

    [pscustomobject]@{
        id = Get-NotionTextProperty -Page $Page -Name "Tracker ID"
        film_id = Get-NotionTextProperty -Page $Page -Name "Film Tracker ID"
        film_title = Get-NotionTextProperty -Page $Page -Name "Film Title"
        director = Get-NotionTextProperty -Page $Page -Name "Director"
        festival = Get-NotionTextProperty -Page $Page -Name "Festival"
        event_date = Get-NotionTextProperty -Page $Page -Name "Event Date"
        availability_types = $types
        providers = @((Get-NotionTextProperty -Page $Page -Name "Providers") -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        countries = @((Get-NotionTextProperty -Page $Page -Name "Countries") -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        source_urls = @((Get-NotionTextProperty -Page $Page -Name "Source URLs") -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        needs_review = $false
    }
}

function ConvertTo-WebFilm {
    param(
        [Parameter(Mandatory = $true)][object]$Film,
        [object[]]$Events = @()
    )

    $tmdbId = ConvertTo-OptionalInt $Film.tmdb_id
    $imdbId = [string](Get-ObjectProperty $Film "imdb_id" "")
    $festivalYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "festival_year" (Get-ObjectProperty $Film "year" $null))
    $filmYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "film_year" $null)
    $availability = @($Events | Where-Object { $_.film_id -eq $Film.id })

    [pscustomobject]@{
        id = $Film.id
        title = $Film.title
        originalTitle = $Film.original_title
        director = $Film.director
        year = $festivalYear
        festivalYear = $festivalYear
        filmYear = $filmYear
        festival = $Film.festival
        region = $Film.region
        section = $Film.section
        sourceUrl = $Film.source_url
        tmdbId = $tmdbId
        imdbId = $imdbId
        imdbUrl = if ([string]::IsNullOrWhiteSpace($imdbId)) { "" } else { "https://www.imdb.com/title/$imdbId/" }
        tmdbUrl = if ($null -eq $tmdbId -or $tmdbId -le 0) { "" } else { "https://www.themoviedb.org/movie/$tmdbId" }
        matchConfidence = ConvertTo-OptionalDouble $Film.match_confidence
        posterUrl = [string](Get-ObjectProperty $Film "poster_url" "")
        overview = [string](Get-ObjectProperty $Film "overview" "")
        tmdbRating = ConvertTo-OptionalDouble $Film.tmdb_rating
        imdbRating = ConvertTo-OptionalDouble (Get-ObjectProperty $Film "imdb_rating" $null)
        imdbVotes = ConvertTo-OptionalInt (Get-ObjectProperty $Film "imdb_votes" $null)
        imdbRatingCheckedAt = [string](Get-ObjectProperty $Film "imdb_rating_checked_at" "")
        ratingSource = [string](Get-ObjectProperty $Film "rating_source" "")
        trackingStatus = [string](Get-ObjectProperty $Film "tracking_status" "pending")
        firstAvailableDate = [string](Get-ObjectProperty $Film "first_available_date" "")
        lastChecked = [string](Get-ObjectProperty $Film "last_checked" "")
        lowConfidence = [bool](Get-ObjectProperty $Film "needs_review" $false)
        availability = @($availability)
        selections = @([pscustomobject]@{
            id = $Film.id
            festival = $Film.festival
            region = $Film.region
            section = $Film.section
            festivalYear = $festivalYear
            sourceUrl = $Film.source_url
        })
    }
}

function Get-WebCanonicalFilmKey {
    param([Parameter(Mandatory = $true)][object]$Film)

    $tmdbId = ConvertTo-OptionalInt $Film.tmdbId
    if ($null -ne $tmdbId -and $tmdbId -gt 0) {
        return "tmdb:$tmdbId"
    }

    $imdbId = [string](Get-ObjectProperty $Film "imdbId" "")
    if (-not [string]::IsNullOrWhiteSpace($imdbId)) {
        return "imdb:$($imdbId.Trim().ToLowerInvariant())"
    }

    $filmYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "filmYear" $null)
    $yearPart = if ($null -ne $filmYear -and $filmYear -gt 0) { [string]$filmYear } else { "" }
    return "title:${yearPart}:$(ConvertTo-NormalizedTitle $Film.title):$(ConvertTo-NormalizedTitle $Film.director)"
}

function Get-SelectionLabel {
    param([Parameter(Mandatory = $true)][object]$Selection)

    $parts = @(
        [string](Get-ObjectProperty $Selection "festival" ""),
        [string](Get-ObjectProperty $Selection "festivalYear" ""),
        [string](Get-ObjectProperty $Selection "section" "")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    return ($parts -join " ")
}

function Merge-WebFilms {
    param([object[]]$Films)

    $byKey = [ordered]@{}
    foreach ($film in @($Films)) {
        $key = Get-WebCanonicalFilmKey -Film $film
        if (-not $byKey.Contains($key)) {
            $film.id = New-StableId "web-film|$key"
            Add-Member -InputObject $film -NotePropertyName "canonicalFilmKey" -NotePropertyValue $key -Force
            $byKey[$key] = $film
            continue
        }

        $existing = $byKey[$key]
        $existing.selections = @(
            @($existing.selections) + @($film.selections) |
                Sort-Object festivalYear, festival, section, sourceUrl -Unique
        )
        $existing.availability = @(
            @($existing.availability) + @($film.availability) |
                Sort-Object event_date, id -Unique
        )

        foreach ($name in @("posterUrl", "overview", "imdbId", "imdbUrl", "tmdbUrl")) {
            $existingValue = [string](Get-ObjectProperty $existing $name "")
            $incomingValue = [string](Get-ObjectProperty $film $name "")
            if ([string]::IsNullOrWhiteSpace($existingValue) -and -not [string]::IsNullOrWhiteSpace($incomingValue)) {
                $existing.$name = $incomingValue
            }
        }

        $existingTmdbId = ConvertTo-OptionalInt $existing.tmdbId
        $incomingTmdbId = ConvertTo-OptionalInt $film.tmdbId
        if (($null -eq $existingTmdbId -or $existingTmdbId -le 0) -and $null -ne $incomingTmdbId -and $incomingTmdbId -gt 0) {
            $existing.tmdbId = $incomingTmdbId
        }

        $existingFilmYear = ConvertTo-OptionalInt $existing.filmYear
        $incomingFilmYear = ConvertTo-OptionalInt $film.filmYear
        if (($null -eq $existingFilmYear -or $existingFilmYear -le 0) -and $null -ne $incomingFilmYear -and $incomingFilmYear -gt 0) {
            $existing.filmYear = $incomingFilmYear
        }

        $existingRating = ConvertTo-OptionalDouble $existing.tmdbRating
        $incomingRating = ConvertTo-OptionalDouble $film.tmdbRating
        if (($null -eq $existingRating -or $existingRating -le 0) -and $null -ne $incomingRating -and $incomingRating -gt 0) {
            $existing.tmdbRating = $incomingRating
        }

        $existingImdbRating = ConvertTo-OptionalDouble (Get-ObjectProperty $existing "imdbRating" $null)
        $incomingImdbRating = ConvertTo-OptionalDouble (Get-ObjectProperty $film "imdbRating" $null)
        if (($null -eq $existingImdbRating -or $existingImdbRating -le 0) -and $null -ne $incomingImdbRating -and $incomingImdbRating -gt 0) {
            $existing.imdbRating = $incomingImdbRating
            $existing.ratingSource = "IMDb"
        }
        $existingImdbVotes = ConvertTo-OptionalInt (Get-ObjectProperty $existing "imdbVotes" $null)
        $incomingImdbVotes = ConvertTo-OptionalInt (Get-ObjectProperty $film "imdbVotes" $null)
        if (($null -eq $existingImdbVotes -or $existingImdbVotes -le 0) -and $null -ne $incomingImdbVotes -and $incomingImdbVotes -gt 0) {
            $existing.imdbVotes = $incomingImdbVotes
        }
        if ([string](Get-ObjectProperty $film "imdbRatingCheckedAt" "") -gt [string](Get-ObjectProperty $existing "imdbRatingCheckedAt" "")) {
            $existing.imdbRatingCheckedAt = $film.imdbRatingCheckedAt
        }

        $existingConfidence = ConvertTo-OptionalDouble $existing.matchConfidence
        $incomingConfidence = ConvertTo-OptionalDouble $film.matchConfidence
        if ($null -ne $incomingConfidence -and ($null -eq $existingConfidence -or $incomingConfidence -gt $existingConfidence)) {
            $existing.matchConfidence = $incomingConfidence
        }

        $existing.lowConfidence = [bool]$existing.lowConfidence -or [bool]$film.lowConfidence
        if ($existing.trackingStatus -ne "available_found" -and $film.trackingStatus -eq "available_found") {
            $existing.trackingStatus = "available_found"
        }
        elseif ($existing.trackingStatus -eq "pending" -and $film.trackingStatus -eq "needs_review") {
            $existing.trackingStatus = "needs_review"
        }

        if ([string]::IsNullOrWhiteSpace([string]$existing.firstAvailableDate) -or
            (-not [string]::IsNullOrWhiteSpace([string]$film.firstAvailableDate) -and [string]$film.firstAvailableDate -lt [string]$existing.firstAvailableDate)) {
            $existing.firstAvailableDate = $film.firstAvailableDate
        }
        if ([string]$film.lastChecked -gt [string]$existing.lastChecked) {
            $existing.lastChecked = $film.lastChecked
        }
    }

    foreach ($film in @($byKey.Values)) {
        $selectionFestivals = @($film.selections | ForEach-Object { $_.festival } | Where-Object { $_ } | Select-Object -Unique)
        $film.festival = ($selectionFestivals -join ", ")
        $film.section = if (@($film.selections).Count -eq 1) { $film.selections[0].section } else { "$(@($film.selections).Count) selections" }
        Add-Member -InputObject $film -NotePropertyName "selectionSummary" -NotePropertyValue $(if (@($selectionFestivals).Count -gt 0) { $selectionFestivals -join " / " } else { "Official selection" }) -Force
        Add-Member -InputObject $film -NotePropertyName "selectionLabels" -NotePropertyValue @($film.selections | ForEach-Object { Get-SelectionLabel -Selection $_ } | Where-Object { $_ }) -Force
    }

    return @($byKey.Values | Sort-Object trackingStatus, title, director)
}

$films = @()
$events = @()

if ($UseNotion) {
    $filmsDb = Get-EnvValue "NOTION_FILMS_DATABASE_ID"
    $eventsDb = Get-EnvValue "NOTION_EVENTS_DATABASE_ID"
    if ([string]::IsNullOrWhiteSpace($filmsDb) -or [string]::IsNullOrWhiteSpace($eventsDb)) {
        throw "Set NOTION_FILMS_DATABASE_ID and NOTION_EVENTS_DATABASE_ID before exporting from Notion."
    }

    $films = @(Import-NotionFilms -DatabaseId $filmsDb)
    $events = @(Get-NotionDatabasePages -DatabaseId $eventsDb | ForEach-Object { ConvertTo-EventRecord -Page $_ })
}
else {
    $filmsPath = Join-Path $StateDir "films.json"
    $eventsPath = Join-Path $StateDir "events.json"
    $films = @()
    foreach ($film in (Read-JsonFile -Path $filmsPath -Default @())) {
        $films += $film
    }
    $events = @()
    foreach ($event in (Read-JsonFile -Path $eventsPath -Default @())) {
        $events += $event
    }
}

$selectionRecords = @($films | ForEach-Object { ConvertTo-WebFilm -Film $_ -Events $events })
$webFilms = @(Merge-WebFilms -Films $selectionRecords)
$years = @(
    $selectionRecords |
        ForEach-Object { ConvertTo-OptionalInt $_.festivalYear } |
        Where-Object { $null -ne $_ } |
        Sort-Object -Descending -Unique
)
$festivals = @(
    $webFilms |
        ForEach-Object { @($_.selections) } |
        ForEach-Object { $_.festival } |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Sort-Object -Unique
)
$payload = [pscustomobject]@{
    generatedAt = (Get-Date).ToString("o")
    totals = [pscustomobject]@{
        films = $webFilms.Count
        selections = $selectionRecords.Count
        available = @($webFilms | Where-Object { $_.trackingStatus -eq "available_found" }).Count
        events = $events.Count
    }
    diagnostics = [pscustomobject]@{
        lowConfidence = @($webFilms | Where-Object { $_.lowConfidence }).Count
        trackingNeedsReview = @($webFilms | Where-Object { $_.trackingStatus -eq "needs_review" }).Count
        unmatched = @($webFilms | Where-Object {
            ($null -eq (ConvertTo-OptionalInt $_.tmdbId) -or (ConvertTo-OptionalInt $_.tmdbId) -le 0) -and
            [string]::IsNullOrWhiteSpace([string]$_.imdbId)
        }).Count
    }
    festivals = $festivals
    years = $years
    festivalYears = $years
    selectionCount = $selectionRecords.Count
    films = $webFilms
    events = $events
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}

$payload | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "Exported $($webFilms.Count) films and $($events.Count) events to $OutputPath"
