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

    $primarySourceUrl = Get-NotionTextProperty -Page $Page -Name "Primary Source URL"
    $legacySourceUrls = @((Get-NotionTextProperty -Page $Page -Name "Source URLs") -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne "[truncated]" })
    if ([string]::IsNullOrWhiteSpace($primarySourceUrl) -and $legacySourceUrls.Count -gt 0) {
        $primarySourceUrl = [string]$legacySourceUrls[0]
    }
    $sourceUrlCount = ConvertTo-OptionalInt (Get-NotionTextProperty -Page $Page -Name "Source URL Count")
    if ($null -eq $sourceUrlCount) { $sourceUrlCount = $legacySourceUrls.Count }
    $sourceUrls = if ([string]::IsNullOrWhiteSpace($primarySourceUrl)) { @($legacySourceUrls) } else { @($primarySourceUrl) }
    $filmProperty = Get-ObjectProperty $Page.properties "Film"
    $filmRelationIds = @()
    if ($null -ne $filmProperty -and $null -ne $filmProperty.relation) {
        $filmRelationIds = @($filmProperty.relation | ForEach-Object { $_.id } | Where-Object { $_ })
    }

    [pscustomobject]@{
        id = Get-NotionTextProperty -Page $Page -Name "Tracker ID"
        film_id = Get-NotionTextProperty -Page $Page -Name "Film Tracker ID"
        canonical_key = Get-NotionTextProperty -Page $Page -Name "Canonical Key"
        film_relation_ids = $filmRelationIds
        film_title = Get-NotionTextProperty -Page $Page -Name "Film Title"
        director = Get-NotionTextProperty -Page $Page -Name "Director"
        festival = Get-NotionTextProperty -Page $Page -Name "Festival"
        event_date = Get-NotionTextProperty -Page $Page -Name "Event Date"
        availability_types = $types
        providers = @((Get-NotionTextProperty -Page $Page -Name "Providers") -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        countries = @((Get-NotionTextProperty -Page $Page -Name "Countries") -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        primary_source_url = $primarySourceUrl
        source_url_count = $sourceUrlCount
        provider_count = ConvertTo-OptionalInt (Get-NotionTextProperty -Page $Page -Name "Provider Count")
        country_count = ConvertTo-OptionalInt (Get-NotionTextProperty -Page $Page -Name "Country Count")
        source_urls = $sourceUrls
        needs_review = $false
    }
}

function Test-EventMatchesFilm {
    param(
        [Parameter(Mandatory = $true)][object]$Event,
        [Parameter(Mandatory = $true)][object]$Film,
        [object[]]$Selections = @()
    )

    $filmId = [string](Get-ObjectProperty $Film "id" "")
    $eventFilmId = [string](Get-ObjectProperty $Event "film_id" "")
    if (-not [string]::IsNullOrWhiteSpace($eventFilmId) -and $eventFilmId -eq $filmId) {
        return $true
    }

    $selectionIds = @($Selections | ForEach-Object { [string](Get-ObjectProperty $_ "id" "") } | Where-Object { $_ })
    if (-not [string]::IsNullOrWhiteSpace($eventFilmId) -and $selectionIds -contains $eventFilmId) {
        return $true
    }

    $eventCanonicalKey = [string](Get-ObjectProperty $Event "canonical_key" "")
    $filmCanonicalKey = [string](Get-ObjectProperty $Film "canonical_key" (Get-ObjectProperty $Film "canonicalFilmKey" ""))
    if ([string]::IsNullOrWhiteSpace($filmCanonicalKey)) {
        $filmCanonicalKey = Get-CanonicalFilmKey -Film $Film
    }
    if (-not [string]::IsNullOrWhiteSpace($eventCanonicalKey) -and $eventCanonicalKey -eq $filmCanonicalKey) {
        return $true
    }

    $filmPageId = [string](Get-ObjectProperty $Film "notion_page_id" "")
    $eventFilmRelationIds = @((Get-ObjectProperty $Event "film_relation_ids" @()) | ForEach-Object { [string]$_ } | Where-Object { $_ })
    return (-not [string]::IsNullOrWhiteSpace($filmPageId) -and $eventFilmRelationIds -contains $filmPageId)
}

function Resolve-YearMetadata {
    param(
        [Parameter(Mandatory = $true)][object]$Film,
        [object[]]$FestivalYears = @()
    )

    $validFestivalYears = @(
        $FestivalYears |
            ForEach-Object { ConvertTo-OptionalInt $_ } |
            Where-Object { $null -ne $_ -and $_ -gt 0 } |
            Sort-Object
    )
    $minFestivalYear = if (@($validFestivalYears).Count -gt 0) { [int]$validFestivalYears[0] } else { $null }
    $premiereYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "premiere_year" (Get-ObjectProperty $Film "premiereYear" $null))
    $releaseYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "release_year" (Get-ObjectProperty $Film "releaseYear" $null))
    $filmYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "film_year" (Get-ObjectProperty $Film "filmYear" $null))
    $yearSource = [string](Get-ObjectProperty $Film "year_source" (Get-ObjectProperty $Film "yearSource" ""))
    $festival = [string](Get-ObjectProperty $Film "festival" "")
    if ([string]::IsNullOrWhiteSpace($festival) -and $null -ne $Film.PSObject.Properties["selections"]) {
        $festival = [string](@($Film.selections | ForEach-Object { $_.festival } | Where-Object { $_ } | Select-Object -First 1))
    }

    if ($null -eq $releaseYear -and $null -ne $filmYear -and $null -ne $minFestivalYear -and $filmYear -gt $minFestivalYear) {
        $releaseYear = $filmYear
    }

    if ($null -eq $premiereYear) {
        if ($null -ne $filmYear -and ($null -eq $minFestivalYear -or $filmYear -le $minFestivalYear)) {
            $premiereYear = $filmYear
            if ([string]::IsNullOrWhiteSpace($yearSource)) { $yearSource = "official_festival" }
        }
        elseif ($festival -eq "Academy Awards" -and $null -ne $minFestivalYear -and $minFestivalYear -gt 1) {
            $premiereYear = $minFestivalYear - 1
            if ([string]::IsNullOrWhiteSpace($yearSource)) { $yearSource = "oscars_eligibility" }
        }
        elseif ($null -ne $minFestivalYear) {
            $premiereYear = $minFestivalYear
            if ([string]::IsNullOrWhiteSpace($yearSource)) { $yearSource = "festival_year_fallback" }
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($yearSource)) {
        $yearSource = "official_festival"
    }

    [pscustomobject]@{
        premiereYear = $premiereYear
        releaseYear = $releaseYear
        yearSource = $yearSource
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
    $yearMetadata = Resolve-YearMetadata -Film $Film -FestivalYears @($festivalYear)
    $availability = @($Events | Where-Object { Test-EventMatchesFilm -Event $_ -Film $Film })

    [pscustomobject]@{
        id = $Film.id
        title = $Film.title
        originalTitle = $Film.original_title
        director = $Film.director
        year = $festivalYear
        festivalYear = $festivalYear
        filmYear = $yearMetadata.premiereYear
        premiereYear = $yearMetadata.premiereYear
        releaseYear = $yearMetadata.releaseYear
        yearSource = $yearMetadata.yearSource
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
        metadataSource = [string](Get-ObjectProperty $Film "metadata_source" "")
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

function ConvertTo-WebCanonicalFilm {
    param(
        [Parameter(Mandatory = $true)][object]$Film,
        [object[]]$Selections = @(),
        [object[]]$Events = @()
    )

    $tmdbId = ConvertTo-OptionalInt $Film.tmdb_id
    $imdbId = [string](Get-ObjectProperty $Film "imdb_id" "")
    $availability = @($Events | Where-Object { Test-EventMatchesFilm -Event $_ -Film $Film -Selections $Selections })
    $festivalYears = @($Selections | ForEach-Object { ConvertTo-OptionalInt (Get-ObjectProperty $_ "festival_year" (Get-ObjectProperty $_ "year" $null)) } | Where-Object { $null -ne $_ })
    $primaryFestivalYear = if (@($festivalYears).Count -gt 0) { @($festivalYears | Sort-Object -Descending)[0] } else { $null }
    $yearMetadata = Resolve-YearMetadata -Film $Film -FestivalYears $festivalYears

    [pscustomobject]@{
        id = $Film.id
        title = $Film.title
        originalTitle = $Film.original_title
        director = $Film.director
        year = $primaryFestivalYear
        festivalYear = $primaryFestivalYear
        filmYear = $yearMetadata.premiereYear
        premiereYear = $yearMetadata.premiereYear
        releaseYear = $yearMetadata.releaseYear
        yearSource = $yearMetadata.yearSource
        festival = ""
        region = ""
        section = ""
        sourceUrl = ""
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
        metadataSource = [string](Get-ObjectProperty $Film "metadata_source" "")
        trackingStatus = [string](Get-ObjectProperty $Film "tracking_status" "pending")
        firstAvailableDate = [string](Get-ObjectProperty $Film "first_available_date" "")
        lastChecked = [string](Get-ObjectProperty $Film "last_checked" "")
        lowConfidence = [bool](Get-ObjectProperty $Film "needs_review" $false)
        availability = @($availability)
        selections = @($Selections | ForEach-Object {
            [pscustomobject]@{
                id = $_.id
                festival = $_.festival
                region = $_.region
                section = $_.section
                festivalYear = ConvertTo-OptionalInt (Get-ObjectProperty $_ "festival_year" (Get-ObjectProperty $_ "year" $null))
                sourceUrl = $_.source_url
            }
        })
        canonicalFilmKey = [string](Get-ObjectProperty $Film "canonical_key" "")
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

    $filmYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "premiereYear" (Get-ObjectProperty $Film "filmYear" $null))
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

function Get-FirstAvailabilityDate {
    param([object[]]$Availability = @())

    $dates = @(
        $Availability |
            ForEach-Object { [string](Get-ObjectProperty $_ "event_date" "") } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object
    )
    if ($dates.Count -eq 0) {
        return ""
    }
    return [string]$dates[0]
}

function Normalize-WebFilmAvailability {
    param([Parameter(Mandatory = $true)][object]$Film)

    $availability = @($Film.availability)
    if ($availability.Count -eq 0) {
        return
    }

    $sourceStatus = [string](Get-ObjectProperty $Film "trackingStatus" "pending")
    Add-Member -InputObject $Film -NotePropertyName "sourceTrackingStatus" -NotePropertyValue $sourceStatus -Force
    $Film.trackingStatus = "available_found"

    if ([string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $Film "firstAvailableDate" ""))) {
        $firstDate = Get-FirstAvailabilityDate -Availability $availability
        if (-not [string]::IsNullOrWhiteSpace($firstDate)) {
            $Film.firstAvailableDate = $firstDate
        }
    }
}

function Merge-WebFilms {
    param([object[]]$Films)

    $normalizedFilms = @()
    $canonicalByFallback = @{}
    foreach ($film in @($Films)) {
        $key = Get-WebCanonicalFilmKey -Film $film
        $fallbackKey = "title:$(ConvertTo-NormalizedTitle $film.title)"
        $strongKey = $null
        if ($key.StartsWith("tmdb:") -or $key.StartsWith("imdb:")) {
            $strongKey = $key
        }
        elseif ($canonicalByFallback.ContainsKey($fallbackKey)) {
            $key = $canonicalByFallback[$fallbackKey]
        }

        if ($null -ne $strongKey) {
            $canonicalByFallback[$fallbackKey] = $strongKey
        }

        Add-Member -InputObject $film -NotePropertyName "_mergeKey" -NotePropertyValue $key -Force
        $normalizedFilms += $film
    }

    foreach ($film in @($normalizedFilms)) {
        $fallbackKey = "title:$(ConvertTo-NormalizedTitle $film.title)"
        if (-not $film._mergeKey.StartsWith("tmdb:") -and -not $film._mergeKey.StartsWith("imdb:") -and $canonicalByFallback.ContainsKey($fallbackKey)) {
            $film._mergeKey = $canonicalByFallback[$fallbackKey]
        }
    }

    $byKey = [ordered]@{}
    foreach ($film in @($normalizedFilms)) {
        $key = [string]$film._mergeKey
        if (-not $byKey.Contains($key)) {
            $film.id = New-StableId "web-film|$key"
            Add-Member -InputObject $film -NotePropertyName "canonicalFilmKey" -NotePropertyValue $key -Force
            $film.PSObject.Properties.Remove("_mergeKey")
            $byKey[$key] = $film
            continue
        }

        $film.PSObject.Properties.Remove("_mergeKey")
        $existing = $byKey[$key]
        $existing.selections = @(
            @($existing.selections) + @($film.selections) |
                Sort-Object festivalYear, festival, section, sourceUrl -Unique
        )
        $existing.availability = @(
            @($existing.availability) + @($film.availability) |
                Sort-Object event_date, id -Unique
        )

        foreach ($name in @("posterUrl", "overview", "imdbId", "imdbUrl", "tmdbUrl", "director", "metadataSource")) {
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

        foreach ($pair in @(
            @{ name = "premiereYear"; incoming = ConvertTo-OptionalInt $film.premiereYear },
            @{ name = "releaseYear"; incoming = ConvertTo-OptionalInt $film.releaseYear }
        )) {
            $existingValue = ConvertTo-OptionalInt (Get-ObjectProperty $existing $pair.name $null)
            if (($null -eq $existingValue -or $existingValue -le 0) -and $null -ne $pair.incoming -and $pair.incoming -gt 0) {
                Set-RecordProperty -Record $existing -Name $pair.name -Value $pair.incoming
            }
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $existing "yearSource" "")) -and -not [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $film "yearSource" ""))) {
            Set-RecordProperty -Record $existing -Name "yearSource" -Value $film.yearSource
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
        Normalize-WebFilmAvailability -Film $film
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
    $canonicalFilmsDb = Get-EnvValue "NOTION_CANONICAL_FILMS_DATABASE_ID"
    $selectionsDb = Get-EnvValue "NOTION_SELECTIONS_DATABASE_ID"
    $filmsDb = Get-EnvValue "NOTION_FILMS_DATABASE_ID"
    $eventsDb = Get-EnvValue "NOTION_EVENTS_DATABASE_ID"
    if ([string]::IsNullOrWhiteSpace($selectionsDb)) {
        $selectionsDb = $filmsDb
    }
    if ([string]::IsNullOrWhiteSpace($eventsDb)) {
        throw "Set NOTION_EVENTS_DATABASE_ID before exporting from Notion."
    }

    $events = @(Get-NotionDatabasePages -DatabaseId $eventsDb | ForEach-Object { ConvertTo-EventRecord -Page $_ })
    if (-not [string]::IsNullOrWhiteSpace($canonicalFilmsDb)) {
        if ([string]::IsNullOrWhiteSpace($selectionsDb)) {
            throw "Set NOTION_SELECTIONS_DATABASE_ID or NOTION_FILMS_DATABASE_ID before exporting selections from Notion."
        }
        $canonicalFilms = @(Import-NotionCanonicalFilms -DatabaseId $canonicalFilmsDb)
        $selections = @(Import-NotionSelections -DatabaseId $selectionsDb)
        $selectionsByFilmPageId = @{}
        foreach ($selection in $selections) {
            foreach ($filmPageId in @($selection.film_relation_ids)) {
                if (-not $selectionsByFilmPageId.ContainsKey($filmPageId)) {
                    $selectionsByFilmPageId[$filmPageId] = New-Object System.Collections.Generic.List[object]
                }
                $selectionsByFilmPageId[$filmPageId].Add($selection) | Out-Null
            }
        }

        $films = @($canonicalFilms | ForEach-Object {
            $filmSelections = @()
            if ($selectionsByFilmPageId.ContainsKey($_.notion_page_id)) {
                $filmSelections = @($selectionsByFilmPageId[$_.notion_page_id].ToArray())
            }
            if (@($filmSelections).Count -eq 0) {
                return
            }
            ConvertTo-WebCanonicalFilm -Film $_ -Selections $filmSelections -Events $events
        })
    }
    else {
        if ([string]::IsNullOrWhiteSpace($filmsDb)) {
            throw "Set NOTION_FILMS_DATABASE_ID before exporting from legacy Notion schema."
        }
        $films = @(Import-NotionFilms -DatabaseId $filmsDb)
    }
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

$usingCanonicalFilms = $UseNotion -and -not [string]::IsNullOrWhiteSpace((Get-EnvValue "NOTION_CANONICAL_FILMS_DATABASE_ID"))
$selectionRecords = if ($usingCanonicalFilms) { @($films) } else { @($films | ForEach-Object { ConvertTo-WebFilm -Film $_ -Events $events }) }
$webFilms = @(Merge-WebFilms -Films $selectionRecords)
if ($usingCanonicalFilms) {
    foreach ($film in @($webFilms)) {
        $selectionFestivals = @($film.selections | ForEach-Object { $_.festival } | Where-Object { $_ } | Select-Object -Unique)
        $film.festival = ($selectionFestivals -join ", ")
        $film.section = if (@($film.selections).Count -eq 1) { $film.selections[0].section } else { "$(@($film.selections).Count) selections" }
        Add-Member -InputObject $film -NotePropertyName "selectionSummary" -NotePropertyValue $(if (@($selectionFestivals).Count -gt 0) { $selectionFestivals -join " / " } else { "Official selection" }) -Force
        Add-Member -InputObject $film -NotePropertyName "selectionLabels" -NotePropertyValue @($film.selections | ForEach-Object { Get-SelectionLabel -Selection $_ } | Where-Object { $_ }) -Force
    }
}
$allSelections = @(
    $webFilms |
        ForEach-Object { @($_.selections) }
)
$festivalYears = @(
    $allSelections |
        ForEach-Object { ConvertTo-OptionalInt (Get-ObjectProperty $_ "festivalYear" $null) } |
        Where-Object { $null -ne $_ } |
        Sort-Object -Descending -Unique
)
$filmYears = @(
    $webFilms |
        ForEach-Object {
            $filmYear = ConvertTo-OptionalInt (Get-ObjectProperty $_ "filmYear" $null)
            if ($null -ne $filmYear) {
                $filmYear
            }
            else {
                @($_.selections) |
                    ForEach-Object { ConvertTo-OptionalInt (Get-ObjectProperty $_ "festivalYear" $null) } |
                    Where-Object { $null -ne $_ } |
                    Sort-Object |
                    Select-Object -First 1
            }
        } |
        Where-Object { $null -ne $_ } |
        Sort-Object -Descending -Unique
)
$premiereYears = @(
    $webFilms |
        ForEach-Object {
            $premiereYear = ConvertTo-OptionalInt (Get-ObjectProperty $_ "premiereYear" $null)
            if ($null -ne $premiereYear) {
                $premiereYear
            }
            else {
                @($_.selections) |
                    ForEach-Object { ConvertTo-OptionalInt (Get-ObjectProperty $_ "festivalYear" $null) } |
                    Where-Object { $null -ne $_ } |
                    Sort-Object |
                    Select-Object -First 1
            }
        } |
        Where-Object { $null -ne $_ } |
        Sort-Object -Descending -Unique
)
$festivals = @(
    $allSelections |
        ForEach-Object { $_.festival } |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Sort-Object -Unique
)
$duplicateCanonicalCount = @(
    $webFilms |
        Group-Object canonicalFilmKey |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Name) -and $_.Count -gt 1 }
).Count

function ConvertTo-DiagnosticFilm {
    param([Parameter(Mandatory = $true)][object]$Film)

    [pscustomobject]@{
        title = [string](Get-ObjectProperty $Film "title" "")
        director = [string](Get-ObjectProperty $Film "director" "")
        festival = [string](Get-ObjectProperty $Film "festival" "")
        festivalYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "festivalYear" $null)
        filmYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "filmYear" $null)
        premiereYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "premiereYear" $null)
        releaseYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "releaseYear" $null)
        yearSource = [string](Get-ObjectProperty $Film "yearSource" "")
        tmdbId = ConvertTo-OptionalInt (Get-ObjectProperty $Film "tmdbId" $null)
        imdbId = [string](Get-ObjectProperty $Film "imdbId" "")
        canonicalFilmKey = [string](Get-ObjectProperty $Film "canonicalFilmKey" "")
        reason = Get-FilmMetadataIssueReason -Film $Film
        selectionLabels = @((Get-ObjectProperty $Film "selectionLabels" @()) | Where-Object { $_ })
    }
}

$missingPosterFilms = @($webFilms | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.posterUrl) })
$missingTmdbFilms = @($webFilms | Where-Object {
    $tmdbId = ConvertTo-OptionalInt $_.tmdbId
    $null -eq $tmdbId -or $tmdbId -le 0
})
$missingDirectorFilms = @($webFilms | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.director) })
$lowConfidenceFilms = @($webFilms | Where-Object { $_.lowConfidence })
$pendingWithAvailabilityFilms = @($webFilms | Where-Object {
    [string](Get-ObjectProperty $_ "sourceTrackingStatus" (Get-ObjectProperty $_ "trackingStatus" "pending")) -eq "pending" -and
    @($_.availability).Count -gt 0
})
foreach ($film in @($webFilms)) {
    $film.PSObject.Properties.Remove("sourceTrackingStatus")
}

$payload = [pscustomobject]@{
    generatedAt = (Get-Date).ToString("o")
    totals = [pscustomobject]@{
        films = @($webFilms).Count
        selections = $allSelections.Count
        available = @($webFilms | Where-Object { $_.trackingStatus -eq "available_found" }).Count
        events = @($events).Count
    }
    diagnostics = [pscustomobject]@{
        lowConfidence = $lowConfidenceFilms.Count
        trackingNeedsReview = @($webFilms | Where-Object { $_.trackingStatus -eq "needs_review" }).Count
        unmatched = @($webFilms | Where-Object {
            ($null -eq (ConvertTo-OptionalInt $_.tmdbId) -or (ConvertTo-OptionalInt $_.tmdbId) -le 0) -and
            [string]::IsNullOrWhiteSpace([string]$_.imdbId)
        }).Count
        missingPoster = $missingPosterFilms.Count
        missingTmdb = $missingTmdbFilms.Count
        missingDirector = $missingDirectorFilms.Count
        duplicateCanonical = $duplicateCanonicalCount
        pendingWithAvailability = $pendingWithAvailabilityFilms.Count
        missingPosterFilms = @($missingPosterFilms | Select-Object -First 50 | ForEach-Object { ConvertTo-DiagnosticFilm -Film $_ })
        missingTmdbFilms = @($missingTmdbFilms | Select-Object -First 50 | ForEach-Object { ConvertTo-DiagnosticFilm -Film $_ })
        missingDirectorFilms = @($missingDirectorFilms | Select-Object -First 50 | ForEach-Object { ConvertTo-DiagnosticFilm -Film $_ })
        lowConfidenceFilms = @($lowConfidenceFilms | Select-Object -First 50 | ForEach-Object { ConvertTo-DiagnosticFilm -Film $_ })
    }
    festivals = $festivals
    years = $premiereYears
    premiereYears = $premiereYears
    filmYears = $premiereYears
    releaseYears = @($webFilms | ForEach-Object { ConvertTo-OptionalInt (Get-ObjectProperty $_ "releaseYear" $null) } | Where-Object { $null -ne $_ } | Sort-Object -Descending -Unique)
    festivalYears = $festivalYears
    selectionCount = $allSelections.Count
    films = @($webFilms)
    events = @($events)
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}

$payload | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "Exported $(@($webFilms).Count) films and $(@($events).Count) events to $OutputPath"
