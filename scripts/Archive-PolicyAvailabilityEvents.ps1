param(
    [string]$FilmsDatabaseId = $env:NOTION_CANONICAL_FILMS_DATABASE_ID,
    [string]$SelectionsDatabaseId = $env:NOTION_SELECTIONS_DATABASE_ID,
    [string]$EventsDatabaseId = $env:NOTION_EVENTS_DATABASE_ID,
    [Parameter(Mandatory = $true)][string[]]$FilmTrackerIds,
    [int]$ExpectedFilmCount = 4,
    [int]$MaximumEventCount = 4,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1"
Import-Module $modulePath -Force

if ([string]::IsNullOrWhiteSpace($FilmsDatabaseId) -or
    [string]::IsNullOrWhiteSpace($SelectionsDatabaseId) -or
    [string]::IsNullOrWhiteSpace($EventsDatabaseId)) {
    throw "Set NOTION_CANONICAL_FILMS_DATABASE_ID, NOTION_SELECTIONS_DATABASE_ID, and NOTION_EVENTS_DATABASE_ID."
}

$films = @(Import-NotionCanonicalFilms -DatabaseId $FilmsDatabaseId)
$selections = @(Import-NotionSelections -DatabaseId $SelectionsDatabaseId)
$events = @(Import-NotionEvents -DatabaseId $EventsDatabaseId)
$plan = Get-PolicyOrphanCleanupPlan -Films $films -Selections $selections -Events $events -FilmTrackerIds $FilmTrackerIds
$targetFilms = @($plan.films)
$targetEvents = @($plan.events)

if ($targetFilms.Count -ne $ExpectedFilmCount) {
    throw "Found $($targetFilms.Count) policy films to archive; expected $ExpectedFilmCount."
}
if ($targetEvents.Count -gt $MaximumEventCount) {
    throw "Found $($targetEvents.Count) policy events to archive; expected no more than $MaximumEventCount."
}

if ($Apply) {
    foreach ($event in $targetEvents) {
        Invoke-NotionRequest -Method PATCH -Path "/v1/pages/$($event.notion_page_id)" -Body @{ archived = $true } | Out-Null
    }
    foreach ($film in $targetFilms) {
        Invoke-NotionRequest -Method PATCH -Path "/v1/pages/$($film.notion_page_id)" -Body @{ archived = $true } | Out-Null
    }
}

[pscustomobject]@{
    mode = if ($Apply) { "apply" } else { "dry_run" }
    archived_films = $targetFilms.Count
    archived_events = $targetEvents.Count
    films = @($targetFilms | Select-Object title, director, id, notion_page_id)
    events = @($targetEvents | Select-Object film_title, festival, event_date, film_id, notion_page_id)
} | ConvertTo-Json -Depth 6
