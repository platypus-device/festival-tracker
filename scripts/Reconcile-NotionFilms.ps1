param(
    [string]$FilmsDatabaseId = $env:NOTION_CANONICAL_FILMS_DATABASE_ID,
    [string]$SelectionsDatabaseId = $env:NOTION_SELECTIONS_DATABASE_ID,
    [string]$EventsDatabaseId = $env:NOTION_EVENTS_DATABASE_ID,
    [switch]$Apply,
    [switch]$ArchiveDuplicates
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

function Get-ReconcileKey {
    param([Parameter(Mandatory = $true)][object]$Film)

    $tmdbId = ConvertTo-OptionalInt (Get-ObjectProperty $Film "tmdb_id" $null)
    if ($null -ne $tmdbId -and $tmdbId -gt 0) {
        return "tmdb:$tmdbId"
    }

    $imdbId = [string](Get-ObjectProperty $Film "imdb_id" "")
    if (-not [string]::IsNullOrWhiteSpace($imdbId)) {
        return "imdb:$($imdbId.Trim().ToLowerInvariant())"
    }

    return ""
}

function Get-FilmRank {
    param([Parameter(Mandatory = $true)][object]$Film)

    $rank = 0
    if (-not [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $Film "director" ""))) { $rank += 100 }
    if (-not [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $Film "poster_url" ""))) { $rank += 20 }
    if (-not [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $Film "overview" ""))) { $rank += 10 }
    if ((ConvertTo-OptionalDouble (Get-ObjectProperty $Film "imdb_rating" $null)) -gt 0) { $rank += 5 }
    if ((ConvertTo-OptionalDouble (Get-ObjectProperty $Film "tmdb_rating" $null)) -gt 0) { $rank += 3 }
    return $rank
}

$films = @(Import-NotionCanonicalFilms -DatabaseId $FilmsDatabaseId)
$selections = @(Import-NotionSelections -DatabaseId $SelectionsDatabaseId)
$events = @(Import-NotionEvents -DatabaseId $EventsDatabaseId)

$duplicateGroups = @(
    $films |
        ForEach-Object {
            $key = Get-ReconcileKey -Film $_
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                [pscustomobject]@{ key = $key; film = $_ }
            }
        } |
        Group-Object key |
        Where-Object { $_.Count -gt 1 }
)

$moves = New-Object System.Collections.Generic.List[object]
$archivePageIds = New-Object System.Collections.Generic.List[string]
foreach ($group in $duplicateGroups) {
    $groupFilms = @($group.Group | ForEach-Object { $_.film })
    $target = @($groupFilms | Sort-Object @{ Expression = { Get-FilmRank -Film $_ }; Descending = $true }, title | Select-Object -First 1)[0]
    foreach ($duplicate in @($groupFilms | Where-Object { $_.notion_page_id -ne $target.notion_page_id })) {
        foreach ($selection in $selections) {
            if (@($selection.film_relation_ids) -contains $duplicate.notion_page_id) {
                $moves.Add([pscustomobject]@{
                    type = "selection"
                    page_id = $selection.notion_page_id
                    title = $selection.title
                    from_film = $duplicate.title
                    to_film = $target.title
                    to_film_page_id = $target.notion_page_id
                }) | Out-Null
            }
        }
        foreach ($event in $events) {
            if (@($event.film_relation_ids) -contains $duplicate.notion_page_id) {
                $moves.Add([pscustomobject]@{
                    type = "event"
                    page_id = $event.notion_page_id
                    title = $event.film_title
                    from_film = $duplicate.title
                    to_film = $target.title
                    to_film_page_id = $target.notion_page_id
                }) | Out-Null
            }
        }
        $archivePageIds.Add($duplicate.notion_page_id) | Out-Null
    }
}

if ($Apply) {
    foreach ($move in @($moves.ToArray())) {
        Set-NotionPageFilmRelation -PageId $move.page_id -FilmPageId $move.to_film_page_id
    }
    if ($ArchiveDuplicates) {
        foreach ($pageId in @($archivePageIds.ToArray() | Select-Object -Unique)) {
            Invoke-NotionRequest -Method PATCH -Path "/v1/pages/$pageId" -Body @{ archived = $true } | Out-Null
        }
    }
}

[pscustomobject]@{
    mode = if ($Apply) { "apply" } else { "dry_run" }
    duplicate_groups = @($duplicateGroups).Count
    relation_moves = @($moves.ToArray()).Count
    duplicate_films_to_archive = @($archivePageIds.ToArray() | Select-Object -Unique).Count
    moves = @($moves.ToArray())
} | ConvertTo-Json -Depth 8
