param(
    [string]$FilmsDatabaseId = $env:NOTION_CANONICAL_FILMS_DATABASE_ID,
    [string]$SelectionsDatabaseId = $env:NOTION_SELECTIONS_DATABASE_ID,
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
    $section = [string](Get-ObjectProperty $Selection "section" "")

    if ($festival -eq "Taipei Film Festival") {
        if ($section -eq "International New Talent Competition") {
            return $false
        }
        $narrativeFeaturePattern = '\u6700\u4f73\u5287\u60c5\u9577\u7247'
        if ($section -like "Taipei Film Awards*" -and $section -match $narrativeFeaturePattern) {
            return $false
        }
        return $true
    }

    if ($festival -eq "Cannes") {
        return -not ($section -eq "In Competition - Feature films" -or $section -eq "Un Certain Regard")
    }

    return $false
}

$selections = @(Import-NotionSelections -DatabaseId $SelectionsDatabaseId)
$outOfScope = @($selections | Where-Object { Test-OutOfScopeSelection -Selection $_ })

if ($Apply) {
    foreach ($selection in $outOfScope) {
        Invoke-NotionRequest -Method PATCH -Path "/v1/pages/$($selection.notion_page_id)" -Body @{ archived = $true } | Out-Null
    }
}

$orphanFilms = @()
if ($ArchiveOrphanFilms -and -not [string]::IsNullOrWhiteSpace($FilmsDatabaseId)) {
    $remainingSelections = if ($Apply) {
        @($selections | Where-Object { -not (Test-OutOfScopeSelection -Selection $_) })
    }
    else {
        $selections
    }
    $remainingFilmIds = @{}
    foreach ($selection in $remainingSelections) {
        foreach ($filmId in @($selection.film_relation_ids)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$filmId)) {
                $remainingFilmIds[[string]$filmId] = $true
            }
        }
    }

    $films = @(Import-NotionCanonicalFilms -DatabaseId $FilmsDatabaseId)
    $orphanFilms = @($films | Where-Object { -not $remainingFilmIds.ContainsKey([string]$_.notion_page_id) })
    if ($Apply) {
        foreach ($film in $orphanFilms) {
            Invoke-NotionRequest -Method PATCH -Path "/v1/pages/$($film.notion_page_id)" -Body @{ archived = $true } | Out-Null
        }
    }
}

[pscustomobject]@{
    mode = if ($Apply) { "apply" } else { "dry_run" }
    out_of_scope_selections = @($outOfScope).Count
    orphan_films = @($orphanFilms).Count
    selections = @($outOfScope | Select-Object title, director, festival, section, notion_page_id)
    films = @($orphanFilms | Select-Object title, director, notion_page_id)
} | ConvertTo-Json -Depth 8
