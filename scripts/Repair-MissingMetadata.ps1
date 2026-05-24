param(
    [switch]$UseNotion,
    [switch]$Apply,
    [int]$Limit = 20,
    [switch]$IncludeLowConfidence,
    [string]$StateDir = (Join-Path (Get-Location) ".tracker")
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1"
Import-Module $modulePath -Force

if ($Limit -le 0) { $Limit = 20 }

$films = @()
if ($UseNotion) {
    $filmsDb = Get-EnvValue "NOTION_CANONICAL_FILMS_DATABASE_ID"
    if ([string]::IsNullOrWhiteSpace($filmsDb)) {
        throw "Set NOTION_CANONICAL_FILMS_DATABASE_ID before repairing Notion metadata."
    }
    $films = @(Import-NotionCanonicalFilms -DatabaseId $filmsDb)
}
else {
    $films = @(Read-JsonFile -Path (Join-Path $StateDir "films.json") -Default @())
}

$candidates = @(
    $films |
        Where-Object { Test-FilmNeedsMetadataRepair -Film $_ -IncludeLowConfidence:$IncludeLowConfidence } |
        Select-Object -First $Limit
)

$results = New-Object System.Collections.Generic.List[object]
$changedFilms = New-Object System.Collections.Generic.List[object]
foreach ($film in $candidates) {
    $result = Repair-FilmMissingMetadata -Film $film -IncludeLowConfidence:$IncludeLowConfidence
    $results.Add($result) | Out-Null
    if ($result.repairable) {
        $changedFilms.Add($result.film) | Out-Null
    }
}

if ($Apply -and $UseNotion -and $changedFilms.Count -gt 0) {
    Sync-NotionState -Films @($changedFilms.ToArray()) -NewEvents @() | Out-Null
}
elseif ($Apply -and -not $UseNotion -and $changedFilms.Count -gt 0) {
    $byId = @{}
    foreach ($film in $films) { $byId[[string]$film.id] = $film }
    foreach ($film in @($changedFilms.ToArray())) { $byId[[string]$film.id] = $film }
    Write-JsonFile -Path (Join-Path $StateDir "films.json") -Value @($byId.Values)
}

$reasonCounts = @{}
foreach ($result in @($results.ToArray())) {
    $reason = [string](Get-ObjectProperty $result "reason" "")
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "repairable" }
    if (-not $reasonCounts.ContainsKey($reason)) { $reasonCounts[$reason] = 0 }
    $reasonCounts[$reason]++
}

[pscustomobject]@{
    mode = if ($Apply) { "apply" } else { "dry_run" }
    checked = $candidates.Count
    repairable = @($results | Where-Object { $_.repairable }).Count
    applied = if ($Apply) { $changedFilms.Count } else { 0 }
    needsReview = @($results | Where-Object { -not $_.repairable }).Count
    reasons = $reasonCounts
    results = @($results | ForEach-Object {
        [pscustomobject]@{
            title = $_.title
            director = $_.director
            tmdb_id = $_.tmdb_id
            imdb_id = $_.imdb_id
            repairable = $_.repairable
            changed_fields = $_.changed_fields
            reason = $_.reason
        }
    })
} | ConvertTo-Json -Depth 8
