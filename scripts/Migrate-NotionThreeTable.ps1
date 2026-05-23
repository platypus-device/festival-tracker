param(
    [string]$FilmsDatabaseId = $env:NOTION_CANONICAL_FILMS_DATABASE_ID,
    [string]$SelectionsDatabaseId = $(if ($env:NOTION_SELECTIONS_DATABASE_ID) { $env:NOTION_SELECTIONS_DATABASE_ID } else { $env:NOTION_FILMS_DATABASE_ID }),
    [string]$EventsDatabaseId = $env:NOTION_EVENTS_DATABASE_ID,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1"
Import-Module $modulePath -Force

$result = Invoke-NotionThreeTableMigration `
    -FilmsDatabaseId $FilmsDatabaseId `
    -SelectionsDatabaseId $SelectionsDatabaseId `
    -EventsDatabaseId $EventsDatabaseId `
    -Apply:$Apply

$result | ConvertTo-Json -Depth 20

if ($Apply -and -not [string]::IsNullOrWhiteSpace([string]$result.films_database_id)) {
    Write-Host ""
    Write-Host "Set this secret/env for the three-table workflow:"
    Write-Host "NOTION_CANONICAL_FILMS_DATABASE_ID=$($result.films_database_id)"
    Write-Host "NOTION_SELECTIONS_DATABASE_ID=$($result.selections_database_id)"
}
