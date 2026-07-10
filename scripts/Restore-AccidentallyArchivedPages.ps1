param(
    [long]$RunId = 29105932205,
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [int]$ExpectedFilms = 283,
    [int]$ExpectedEvents = 89,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1"
Import-Module $modulePath -Force

if ([string]::IsNullOrWhiteSpace($Repository)) {
    $Repository = (gh repo view --json nameWithOwner --jq .nameWithOwner).Trim()
}
if ([string]::IsNullOrWhiteSpace($Repository)) {
    throw "Could not determine the GitHub repository."
}

$pageIds = @{
    films = New-Object System.Collections.Generic.List[string]
    events = New-Object System.Collections.Generic.List[string]
}
$seenIds = @{
    films = @{}
    events = @{}
}
$section = ""
foreach ($line in @(gh run view $RunId --repo $Repository --log)) {
    if ($line -match '"films": \[') {
        $section = "films"
        continue
    }
    if ($line -match '"events": \[') {
        $section = "events"
        continue
    }
    if ($line -match '"notion_page_id":\s*"(?<id>[^"]+)"' -and $section -in @("films", "events")) {
        $id = [string]$Matches.id
        if (-not $seenIds[$section].ContainsKey($id)) {
            $seenIds[$section][$id] = $true
            $pageIds[$section].Add($id) | Out-Null
        }
    }
}

if ($pageIds.films.Count -ne $ExpectedFilms -or $pageIds.events.Count -ne $ExpectedEvents) {
    throw "Recovery run $RunId yielded $($pageIds.films.Count) film pages and $($pageIds.events.Count) event pages; expected $ExpectedFilms and $ExpectedEvents."
}

if ($Apply) {
    foreach ($pageId in @($pageIds.films) + @($pageIds.events)) {
        Invoke-NotionRequest -Method PATCH -Path "/v1/pages/$pageId" -Body @{ archived = $false } | Out-Null
    }
}

[pscustomobject]@{
    mode = if ($Apply) { "apply" } else { "dry_run" }
    source_run = $RunId
    restored_films = $pageIds.films.Count
    restored_events = $pageIds.events.Count
} | ConvertTo-Json
