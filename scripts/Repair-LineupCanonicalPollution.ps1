param(
    [string]$FilmsDatabaseId = $env:NOTION_CANONICAL_FILMS_DATABASE_ID,
    [string]$SelectionsDatabaseId = $env:NOTION_SELECTIONS_DATABASE_ID,
    [string]$EventsDatabaseId = $env:NOTION_EVENTS_DATABASE_ID,
    [datetimeoffset]$IncidentStartUtc = [datetimeoffset]"2026-08-04T01:06:00Z",
    [datetimeoffset]$IncidentEndUtc = [datetimeoffset]"2026-08-04T01:14:00Z",
    [switch]$Apply,
    [switch]$AllowPartial
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1"
Import-Module $modulePath -Force

if ([string]::IsNullOrWhiteSpace($FilmsDatabaseId)) {
    throw "Set NOTION_CANONICAL_FILMS_DATABASE_ID or pass -FilmsDatabaseId."
}
if ([string]::IsNullOrWhiteSpace($SelectionsDatabaseId)) {
    $SelectionsDatabaseId = $env:NOTION_FILMS_DATABASE_ID
}
if ([string]::IsNullOrWhiteSpace($SelectionsDatabaseId) -or [string]::IsNullOrWhiteSpace($EventsDatabaseId)) {
    throw "Set NOTION_SELECTIONS_DATABASE_ID (or NOTION_FILMS_DATABASE_ID) and NOTION_EVENTS_DATABASE_ID."
}
if ($IncidentEndUtc -le $IncidentStartUtc) {
    throw "IncidentEndUtc must be later than IncidentStartUtc."
}

$films = @(Import-NotionCanonicalFilms -DatabaseId $FilmsDatabaseId)
$selections = @(Import-NotionSelections -DatabaseId $SelectionsDatabaseId)
$events = @(Import-NotionEvents -DatabaseId $EventsDatabaseId)
$plan = Get-LineupPollutionRepairPlan `
    -Films $films `
    -Selections $selections `
    -Events $events `
    -IncidentStartUtc $IncidentStartUtc `
    -IncidentEndUtc $IncidentEndUtc

$selectionMoves = @($plan.resolved | ForEach-Object {
    $repair = $_
    @($repair.selections | ForEach-Object {
        [pscustomobject]@{
            page_id = $_.notion_page_id
            title = $_.title
            festival = $_.festival
            from_film_page_id = $repair.film.notion_page_id
            to_film_page_id = $repair.target.notion_page_id
            to_film_id = $repair.target.id
            to_canonical_key = $repair.target.canonical_key
        }
    })
})
$eventMoves = @($plan.resolved | ForEach-Object {
    $repair = $_
    @($repair.events | ForEach-Object {
        [pscustomobject]@{
            page_id = $_.notion_page_id
            tracker_id = $_.id
            title = $_.film_title
            from_film_page_id = $repair.film.notion_page_id
            to_film_page_id = $repair.target.notion_page_id
            to_film_id = $repair.target.id
            to_canonical_key = $repair.target.canonical_key
        }
    })
})

$report = [pscustomobject]@{
    mode = if ($Apply) { "apply" } else { "dry_run" }
    incident_start_utc = $plan.incident_start_utc
    incident_end_utc = $plan.incident_end_utc
    polluted_films = @($plan.polluted_films).Count
    resolved_films = @($plan.resolved).Count
    unresolved_films = @($plan.unresolved).Count
    selection_moves = $selectionMoves.Count
    event_moves = $eventMoves.Count
    films_to_archive = @($plan.resolved).Count
    resolved = @($plan.resolved | ForEach-Object {
        [pscustomobject]@{
            title = $_.film.title
            from_film_page_id = $_.film.notion_page_id
            to_film_page_id = $_.target.notion_page_id
            to_film_id = $_.target.id
            to_canonical_key = $_.target.canonical_key
            selection_moves = @($_.selections).Count
            event_moves = @($_.events).Count
        }
    })
    unresolved = @($plan.unresolved | ForEach-Object {
        [pscustomobject]@{
            title = $_.film.title
            film_page_id = $_.film.notion_page_id
            reason = $_.reason
            selections = @($_.selections).Count
            events = @($_.events).Count
            candidates = @($_.candidates | ForEach-Object {
                [pscustomobject]@{
                    title = $_.title
                    director = $_.director
                    tmdb_id = $_.tmdb_id
                    imdb_id = $_.imdb_id
                    film_page_id = $_.notion_page_id
                }
            })
        }
    })
}

if ($Apply -and @($plan.unresolved).Count -gt 0 -and -not $AllowPartial) {
    $report | ConvertTo-Json -Depth 10
    throw "Refusing to apply because $(@($plan.unresolved).Count) incident film(s) do not have a unique recovery target. Review the dry-run output or pass -AllowPartial explicitly."
}

if ($Apply) {
    foreach ($repair in @($plan.resolved)) {
        foreach ($selection in @($repair.selections)) {
            Set-NotionPageFilmRelation -PageId $selection.notion_page_id -FilmPageId $repair.target.notion_page_id
        }
        foreach ($event in @($repair.events)) {
            Set-RecordProperty -Record $event -Name "film_id" -Value $repair.target.id
            Set-RecordProperty -Record $event -Name "canonical_key" -Value $repair.target.canonical_key
            Set-RecordProperty -Record $event -Name "film_notion_page_id" -Value $repair.target.notion_page_id
            Sync-NotionEvent -Event $event -DatabaseId $EventsDatabaseId | Out-Null
        }
        Invoke-NotionRequest -Method PATCH -Path "/v1/pages/$($repair.film.notion_page_id)" -Body @{ archived = $true } | Out-Null
    }
}

$report | ConvertTo-Json -Depth 10
