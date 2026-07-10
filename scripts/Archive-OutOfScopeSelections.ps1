param(
    [string]$FilmsDatabaseId = $env:NOTION_CANONICAL_FILMS_DATABASE_ID,
    [string]$SelectionsDatabaseId = $env:NOTION_SELECTIONS_DATABASE_ID,
    [string]$EventsDatabaseId = $env:NOTION_EVENTS_DATABASE_ID,
    [switch]$Apply,
    [switch]$ArchiveOrphanFilms
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1"
Import-Module $modulePath -Force

if ([string]::IsNullOrWhiteSpace($SelectionsDatabaseId)) {
    $SelectionsDatabaseId = $env:NOTION_FILMS_DATABASE_ID
}
if ([string]::IsNullOrWhiteSpace($SelectionsDatabaseId)) {
    throw "Set NOTION_SELECTIONS_DATABASE_ID or NOTION_FILMS_DATABASE_ID."
}

function Test-OutOfScopeSelection {
    param([Parameter(Mandatory = $true)][object]$Selection)

    $festival = [string](Get-ObjectProperty $Selection "festival" "")
    return $festival -in @("Taipei Film Festival", "Taipei Golden Horse Film Festival")
}

$selections = @(Import-NotionSelections -DatabaseId $SelectionsDatabaseId)
$outOfScope = @(
    $selections |
        Where-Object { Test-OutOfScopeSelection -Selection $_ }
)
$outOfScopeSelectionPageIds = @{}
foreach ($selection in $outOfScope) {
    $outOfScopeSelectionPageIds[[string]$selection.notion_page_id] = $true
}

$orphanFilms = @()
$orphanEvents = @()
if ($ArchiveOrphanFilms -and -not [string]::IsNullOrWhiteSpace($FilmsDatabaseId)) {
    if ([string]::IsNullOrWhiteSpace($EventsDatabaseId)) {
        throw "Set NOTION_EVENTS_DATABASE_ID when archiving orphan films so dependent availability events can also be archived."
    }

    $remainingSelections = @(
        $selections |
            Where-Object { -not $outOfScopeSelectionPageIds.ContainsKey([string]$_.notion_page_id) }
    )
    $remainingFilmIds = @{}
    foreach ($selection in $remainingSelections) {
        foreach ($filmId in @($selection.film_relation_ids)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$filmId)) {
                $remainingFilmIds[[string]$filmId] = $true
            }
        }
    }

    $affectedFilmPageIds = @{}
    foreach ($selection in $outOfScope) {
        foreach ($filmId in @($selection.film_relation_ids)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$filmId)) {
                $affectedFilmPageIds[[string]$filmId] = $true
            }
        }
    }

    $films = @(Import-NotionCanonicalFilms -DatabaseId $FilmsDatabaseId)
    $orphanFilms = @(
        $films |
            Where-Object {
                $affectedFilmPageIds.ContainsKey([string]$_.notion_page_id) -and
                -not $remainingFilmIds.ContainsKey([string]$_.notion_page_id)
            }
    )

    $orphanFilmPageIds = @{}
    $orphanFilmTrackerIds = @{}
    $orphanCanonicalKeys = @{}
    foreach ($film in $orphanFilms) {
        $orphanFilmPageIds[[string]$film.notion_page_id] = $true
        $orphanFilmTrackerIds[[string]$film.id] = $true
        $orphanCanonicalKeys[[string]$film.canonical_key] = $true
    }
    $orphanSelectionIds = @{}
    foreach ($selection in $outOfScope) {
        $selectionFilmRelationIds = @($selection.film_relation_ids | ForEach-Object { [string]$_ } | Where-Object { $_ })
        if ($selectionFilmRelationIds.Count -gt 0 -and @($selectionFilmRelationIds | Where-Object { $orphanFilmPageIds.ContainsKey($_) }).Count -eq $selectionFilmRelationIds.Count) {
            $orphanSelectionIds[[string]$selection.id] = $true
        }
    }

    $events = @(Import-NotionEvents -DatabaseId $EventsDatabaseId)
    $orphanEvents = @(
        $events |
            Where-Object {
                $relationIds = @($_.film_relation_ids | ForEach-Object { [string]$_ } | Where-Object { $_ })
                $allRelationsOrphaned = $relationIds.Count -gt 0 -and @($relationIds | Where-Object { $orphanFilmPageIds.ContainsKey($_) }).Count -eq $relationIds.Count
                $linkedByIdentity = $orphanFilmTrackerIds.ContainsKey([string]$_.film_id) -or
                    $orphanCanonicalKeys.ContainsKey([string]$_.canonical_key) -or
                    $orphanSelectionIds.ContainsKey([string]$_.film_id)
                $allRelationsOrphaned -or $linkedByIdentity
            }
    )
}

if ($Apply) {
    foreach ($selection in $outOfScope) {
        Invoke-NotionRequest -Method PATCH -Path "/v1/pages/$($selection.notion_page_id)" -Body @{ archived = $true } | Out-Null
    }
    foreach ($event in $orphanEvents) {
        Invoke-NotionRequest -Method PATCH -Path "/v1/pages/$($event.notion_page_id)" -Body @{ archived = $true } | Out-Null
    }
    foreach ($film in $orphanFilms) {
        Invoke-NotionRequest -Method PATCH -Path "/v1/pages/$($film.notion_page_id)" -Body @{ archived = $true } | Out-Null
    }
}

[pscustomobject]@{
    mode = if ($Apply) { "apply" } else { "dry_run" }
    out_of_scope_selections = @($outOfScope).Count
    orphan_films = @($orphanFilms).Count
    orphan_events = @($orphanEvents).Count
    selections = @($outOfScope | Select-Object title, director, festival, section, notion_page_id)
    films = @($orphanFilms | Select-Object title, director, notion_page_id)
    events = @($orphanEvents | Select-Object film_title, festival, event_date, notion_page_id)
} | ConvertTo-Json -Depth 8
