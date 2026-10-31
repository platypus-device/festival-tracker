param(
    [string]$FilmsDatabaseId = $env:NOTION_CANONICAL_FILMS_DATABASE_ID,
    [string]$SelectionsDatabaseId = $env:NOTION_SELECTIONS_DATABASE_ID,
    [string]$EventsDatabaseId = $env:NOTION_EVENTS_DATABASE_ID,
    [ValidateRange(0, 60000)][int]$MinIntervalMs = 3000,
    [ValidateRange(1, 120)][int]$MaxDurationMinutes = 25,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1") -Force
if ([string]::IsNullOrWhiteSpace($FilmsDatabaseId) -or [string]::IsNullOrWhiteSpace($SelectionsDatabaseId) -or [string]::IsNullOrWhiteSpace($EventsDatabaseId)) {
    throw "Set NOTION_CANONICAL_FILMS_DATABASE_ID, NOTION_SELECTIONS_DATABASE_ID and NOTION_EVENTS_DATABASE_ID before syncing YTS."
}
$films = @(Import-NotionCanonicalFilms -DatabaseId $FilmsDatabaseId)
$selections = @(Import-NotionSelections -DatabaseId $SelectionsDatabaseId)
$events = @(Import-NotionEvents -DatabaseId $EventsDatabaseId)
$activeFilms = @(Select-YtsAvailableFilms -Films $films -Selections $selections -Events $events)
$summary = Sync-NotionYtsCatalog -Films $activeFilms -DatabaseId $FilmsDatabaseId -MinIntervalMs $MinIntervalMs -MaxDurationMinutes $MaxDurationMinutes -DryRun:$DryRun
$summary | ConvertTo-Json
if ($env:GITHUB_STEP_SUMMARY) {
    @"
### YTS catalog sync
- Candidates: $($summary.candidates)
- API requests: $($summary.requests)
- Saved: $($summary.updated) ($($summary.found) found, $($summary.not_found) not found)
- Failed requests: $($summary.failed)
- Deferred: $($summary.deferred)
- Stop reason: $($summary.stopped)
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding UTF8
}
