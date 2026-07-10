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

function Get-SelectionFestivalYear {
    param([Parameter(Mandatory = $true)][object]$Selection)

    $festivalYear = ConvertTo-OptionalInt (Get-ObjectProperty $Selection "festival_year" $null)
    if ($null -ne $festivalYear) {
        return $festivalYear
    }
    return ConvertTo-OptionalInt (Get-ObjectProperty $Selection "year" $null)
}

function Get-GoldenHorseWinnerTitleMap {
    param([object[]]$Selections = @())

    $winnerTitlesBySource = @{}
    $unresolvedSources = New-Object System.Collections.Generic.List[object]
    $sourceGroups = @(
        $Selections |
            ForEach-Object {
                [pscustomobject]@{
                    source_url = [string](Get-ObjectProperty $_ "source_url" "")
                    festival_year = Get-SelectionFestivalYear -Selection $_
                }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.source_url) } |
            Group-Object source_url
    )

    foreach ($group in $sourceGroups) {
        $sourceUrl = [string]$group.Name
        $year = @($group.Group | ForEach-Object { $_.festival_year } | Where-Object { $null -ne $_ } | Select-Object -First 1)
        $winnerYear = if ($year.Count -gt 0) { [int]$year[0] } else { (Get-Date).Year }
        try {
            $html = Invoke-TextRequest -Url $sourceUrl
            $winners = @(
                ConvertFrom-LineupHtml -Html $html -Festival "Taipei Golden Horse Film Festival" -Region "Taiwan" -SourceUrl $sourceUrl -Parser "golden_horse_awards" -Year $winnerYear -WinnerOnly
            )
            if ($winners.Count -ne 1) {
                throw "Expected exactly one Best Narrative Feature winner, found $($winners.Count)."
            }
            $winnerTitlesBySource[$sourceUrl] = ConvertTo-NormalizedTitle ([string]$winners[0].title)
        }
        catch {
            $unresolvedSources.Add([pscustomobject]@{
                source_url = $sourceUrl
                reason = $_.Exception.Message
            }) | Out-Null
            Write-Warning "Skipping Golden Horse cleanup for ${sourceUrl}: $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        winner_titles_by_source = $winnerTitlesBySource
        unresolved_sources = @($unresolvedSources.ToArray())
    }
}

function Test-OutOfScopeSelection {
    param(
        [Parameter(Mandatory = $true)][object]$Selection,
        [hashtable]$GoldenHorseWinnerTitlesBySource = @{}
    )

    $festival = [string](Get-ObjectProperty $Selection "festival" "")

    if ($festival -eq "Taipei Film Festival") {
        return $true
    }

    if ($festival -eq "Taipei Golden Horse Film Festival") {
        $sourceUrl = [string](Get-ObjectProperty $Selection "source_url" "")
        if ([string]::IsNullOrWhiteSpace($sourceUrl) -or -not $GoldenHorseWinnerTitlesBySource.ContainsKey($sourceUrl)) {
            return $false
        }

        $winnerTitle = [string]$GoldenHorseWinnerTitlesBySource[$sourceUrl]
        $selectionTitle = ConvertTo-NormalizedTitle ([string](Get-ObjectProperty $Selection "title" ""))
        return [string]::IsNullOrWhiteSpace($selectionTitle) -or $selectionTitle -ne $winnerTitle
    }

    return $false
}

$selections = @(Import-NotionSelections -DatabaseId $SelectionsDatabaseId)
$goldenHorseSelections = @($selections | Where-Object { [string](Get-ObjectProperty $_ "festival" "") -eq "Taipei Golden Horse Film Festival" })
$goldenHorseWinnerData = Get-GoldenHorseWinnerTitleMap -Selections $goldenHorseSelections
$outOfScope = @(
    $selections |
        Where-Object {
            Test-OutOfScopeSelection -Selection $_ -GoldenHorseWinnerTitlesBySource $goldenHorseWinnerData.winner_titles_by_source
        }
)
$goldenHorseWinnerSelections = @(
    $goldenHorseSelections |
        Where-Object {
            $sourceUrl = [string](Get-ObjectProperty $_ "source_url" "")
            $sourceUrl -and
            $goldenHorseWinnerData.winner_titles_by_source.ContainsKey($sourceUrl) -and
            (ConvertTo-NormalizedTitle ([string](Get-ObjectProperty $_ "title" ""))) -eq $goldenHorseWinnerData.winner_titles_by_source[$sourceUrl]
        }
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

    $films = @(Import-NotionCanonicalFilms -DatabaseId $FilmsDatabaseId)
    $orphanFilms = @($films | Where-Object { -not $remainingFilmIds.ContainsKey([string]$_.notion_page_id) })

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
    foreach ($selection in $goldenHorseWinnerSelections) {
        if ([string](Get-ObjectProperty $selection "section" "") -eq "Best Narrative Feature - Winner") {
            continue
        }
        Invoke-NotionRequest -Method PATCH -Path "/v1/pages/$($selection.notion_page_id)" -Body @{
            properties = @{
                "Section" = New-RichTextProperty "Best Narrative Feature - Winner"
            }
        } | Out-Null
    }
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
    golden_horse_winners_relabelled = @($goldenHorseWinnerSelections | Where-Object { [string](Get-ObjectProperty $_ "section" "") -ne "Best Narrative Feature - Winner" }).Count
    unresolved_golden_horse_sources = @($goldenHorseWinnerData.unresolved_sources)
    selections = @($outOfScope | Select-Object title, director, festival, section, notion_page_id)
    films = @($orphanFilms | Select-Object title, director, notion_page_id)
    events = @($orphanEvents | Select-Object film_title, festival, event_date, notion_page_id)
} | ConvertTo-Json -Depth 8
