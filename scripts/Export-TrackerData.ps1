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
        needs_review = [bool](Get-ObjectProperty (Get-ObjectProperty $Page.properties "Needs Review") "checkbox" $false)
    }
}

function ConvertTo-WebFilm {
    param(
        [Parameter(Mandatory = $true)][object]$Film,
        [object[]]$Events = @()
    )

    $tmdbId = ConvertTo-OptionalInt $Film.tmdb_id
    $imdbId = [string](Get-ObjectProperty $Film "imdb_id" "")
    $availability = @($Events | Where-Object { $_.film_id -eq $Film.id })

    [pscustomobject]@{
        id = $Film.id
        title = $Film.title
        originalTitle = $Film.original_title
        director = $Film.director
        year = ConvertTo-OptionalInt $Film.year
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
        trackingStatus = [string](Get-ObjectProperty $Film "tracking_status" "pending")
        firstAvailableDate = [string](Get-ObjectProperty $Film "first_available_date" "")
        lastChecked = [string](Get-ObjectProperty $Film "last_checked" "")
        needsReview = [bool](Get-ObjectProperty $Film "needs_review" $false)
        availability = @($availability)
    }
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
    $films = @(Read-JsonFile -Path $filmsPath -Default @())
    $events = @(Read-JsonFile -Path $eventsPath -Default @())
}

$webFilms = @($films | ForEach-Object { ConvertTo-WebFilm -Film $_ -Events $events })
$years = @(
    $webFilms |
        ForEach-Object { ConvertTo-OptionalInt $_.year } |
        Where-Object { $null -ne $_ } |
        Sort-Object -Descending -Unique
)
$payload = [pscustomobject]@{
    generatedAt = (Get-Date).ToString("o")
    totals = [pscustomobject]@{
        films = $webFilms.Count
        available = @($webFilms | Where-Object { $_.trackingStatus -eq "available_found" }).Count
        needsReview = @($webFilms | Where-Object { $_.needsReview }).Count
        events = $events.Count
    }
    festivals = @($webFilms | ForEach-Object { $_.festival } | Where-Object { $_ } | Sort-Object -Unique)
    years = $years
    films = $webFilms
    events = $events
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}

$payload | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "Exported $($webFilms.Count) films and $($events.Count) events to $OutputPath"
