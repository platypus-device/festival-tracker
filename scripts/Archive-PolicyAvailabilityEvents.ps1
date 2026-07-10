param(
    [string]$EventsDatabaseId = $env:NOTION_EVENTS_DATABASE_ID,
    [Parameter(Mandatory = $true)][string[]]$FilmTrackerIds,
    [int]$ExpectedCount = 4,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1"
Import-Module $modulePath -Force

if ([string]::IsNullOrWhiteSpace($EventsDatabaseId)) {
    throw "Set NOTION_EVENTS_DATABASE_ID."
}

$targetIds = @{}
foreach ($filmTrackerId in $FilmTrackerIds) {
    $targetIds[[string]$filmTrackerId] = $true
}

$events = @(
    Import-NotionEvents -DatabaseId $EventsDatabaseId |
        Where-Object { $targetIds.ContainsKey([string]$_.film_id) }
)
if ($events.Count -ne $ExpectedCount) {
    throw "Found $($events.Count) policy events to archive; expected $ExpectedCount."
}

if ($Apply) {
    foreach ($event in $events) {
        Invoke-NotionRequest -Method PATCH -Path "/v1/pages/$($event.notion_page_id)" -Body @{ archived = $true } | Out-Null
    }
}

[pscustomobject]@{
    mode = if ($Apply) { "apply" } else { "dry_run" }
    archived_events = $events.Count
    events = @($events | Select-Object film_title, festival, event_date, film_id, notion_page_id)
} | ConvertTo-Json -Depth 6
