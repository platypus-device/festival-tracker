param(
    [Parameter(Mandatory = $true)]
    [string]$ParentPageId
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1"
Import-Module $modulePath -Force

$result = New-NotionTrackerDatabases -ParentPageId $ParentPageId

Write-Host "Created Notion databases:"
Write-Host "NOTION_FILMS_DATABASE_ID=$($result.films_database_id)"
Write-Host "NOTION_EVENTS_DATABASE_ID=$($result.events_database_id)"
Write-Host "Films: $($result.films_database_url)"
Write-Host "Events: $($result.events_database_url)"
