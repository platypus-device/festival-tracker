param(
    [string]$DataPath = ".\web\data\tracker-data.json",
    [switch]$UseNotion,
    [string]$FilmsDatabaseId = $env:NOTION_CANONICAL_FILMS_DATABASE_ID,
    [string]$SelectionsDatabaseId = $env:NOTION_SELECTIONS_DATABASE_ID,
    [switch]$StrictWarnings
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1") -Force

function Add-QualityIssue {
    param(
        [System.Collections.Generic.List[object]]$List,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$Count = 1
    )

    $List.Add([pscustomobject]@{
        code = $Code
        message = $Message
        count = $Count
    }) | Out-Null
}

function Test-TaipeiSelectionInScope {
    param([Parameter(Mandatory = $true)][object]$Selection)

    $festival = [string](Get-ObjectProperty $Selection "festival" "")
    if ($festival -ne "Taipei Film Festival") {
        return $true
    }

    $section = [string](Get-ObjectProperty $Selection "section" "")
    return (
        $section -eq "International New Talent Competition" -or
        $section -match '\u6700\u4f73\u5287\u60c5\u9577\u7247'
    )
}

function Get-SelectionFestivalYear {
    param([Parameter(Mandatory = $true)][object]$Selection)

    $festivalYear = ConvertTo-OptionalInt (Get-ObjectProperty $Selection "festivalYear" $null)
    if ($null -ne $festivalYear) { return $festivalYear }
    $festivalYear = ConvertTo-OptionalInt (Get-ObjectProperty $Selection "festival_year" $null)
    if ($null -ne $festivalYear) { return $festivalYear }
    return ConvertTo-OptionalInt (Get-ObjectProperty $Selection "year" $null)
}

function Test-SelectionSourceYearMatches {
    param([Parameter(Mandatory = $true)][object]$Selection)

    $sourceUrl = [string](Get-ObjectProperty $Selection "sourceUrl" (Get-ObjectProperty $Selection "source_url" ""))
    if ($sourceUrl -notmatch '/(?<urlYear>20\d{2})/') {
        return $true
    }

    $festivalYear = Get-SelectionFestivalYear -Selection $Selection
    return ($null -eq $festivalYear -or $festivalYear -eq [int]$Matches.urlYear)
}

function Get-FilmPremiereYear {
    param([Parameter(Mandatory = $true)][object]$Film)

    $premiereYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "premiereYear" $null)
    if ($null -ne $premiereYear) { return $premiereYear }
    return ConvertTo-OptionalInt (Get-ObjectProperty $Film "premiere_year" $null)
}

function Get-FilmEarliestFestivalYear {
    param([Parameter(Mandatory = $true)][object]$Film)

    $years = @(
        @($Film.selections) |
            ForEach-Object { Get-SelectionFestivalYear -Selection $_ } |
            Where-Object { $null -ne $_ } |
            Sort-Object
    )
    if (@($years).Count -eq 0) { return $null }
    return [int]$years[0]
}

$qualityErrors = New-Object System.Collections.Generic.List[object]
$qualityWarnings = New-Object System.Collections.Generic.List[object]
$films = @()
$selections = @()

if (Test-Path -LiteralPath $DataPath) {
    $payload = Get-Content -LiteralPath $DataPath -Raw | ConvertFrom-Json
    $films = @($payload.films)
    $selections = @($films | ForEach-Object { @($_.selections) })
    $events = @($payload.events)
    $attachedEventIds = @($films | ForEach-Object { @($_.availability) | ForEach-Object { [string](Get-ObjectProperty $_ "id" "") } | Where-Object { $_ } })
    $orphanedAvailabilityEvents = @($events | Where-Object {
        $eventId = [string](Get-ObjectProperty $_ "id" "")
        -not [string]::IsNullOrWhiteSpace($eventId) -and $attachedEventIds -notcontains $eventId
    })
    if ($orphanedAvailabilityEvents.Count -gt 0) {
        $sample = @(
            $orphanedAvailabilityEvents |
                Select-Object -First 5 |
                ForEach-Object {
                    "{0} ({1}, film_id={2})" -f `
                        (Get-ObjectProperty $_ "film_title" "Untitled"),
                        (Get-ObjectProperty $_ "event_date" "no date"),
                        (Get-ObjectProperty $_ "film_id" "")
                }
        ) -join "; "
        Add-QualityIssue -List $qualityErrors -Code "orphaned_availability_event" -Message "Availability events are not attached to exported film cards: $sample" -Count $orphanedAvailabilityEvents.Count
    }

    $duplicateCanonical = @(
        $films |
            Group-Object canonicalFilmKey |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Name) -and $_.Count -gt 1 }
    )
    if ($duplicateCanonical.Count -gt 0) {
        Add-QualityIssue -List $qualityErrors -Code "duplicate_canonical" -Message "Duplicate canonical film keys are present in web export." -Count $duplicateCanonical.Count
    }

    $oscarsWithoutDirector = @(
        $films | Where-Object {
            [string]::IsNullOrWhiteSpace([string]$_.director) -and
            @($_.selections | Where-Object { [string](Get-ObjectProperty $_ "festival" "") -eq "Academy Awards" }).Count -gt 0
        }
    )
    if ($oscarsWithoutDirector.Count -gt 0) {
        Add-QualityIssue -List $qualityErrors -Code "oscars_missing_director" -Message "Academy Awards films missing director metadata." -Count $oscarsWithoutDirector.Count
    }

    $taipeiOutOfScope = @($selections | Where-Object { -not (Test-TaipeiSelectionInScope -Selection $_) })
    if ($taipeiOutOfScope.Count -gt 0) {
        Add-QualityIssue -List $qualityErrors -Code "taipei_out_of_scope" -Message "Taipei Film Festival selections outside the approved scope are visible in web export." -Count $taipeiOutOfScope.Count
    }

    $sourceYearMismatch = @($selections | Where-Object { -not (Test-SelectionSourceYearMatches -Selection $_) })
    if ($sourceYearMismatch.Count -gt 0) {
        Add-QualityIssue -List $qualityErrors -Code "selection_source_year_mismatch" -Message "Selections have a Festival Year that does not match the year in their source URL." -Count $sourceYearMismatch.Count
    }

    $premiereAfterFestival = @(
        $films | Where-Object {
            $premiereYear = Get-FilmPremiereYear -Film $_
            $earliestFestivalYear = Get-FilmEarliestFestivalYear -Film $_
            $null -ne $premiereYear -and $null -ne $earliestFestivalYear -and $premiereYear -gt $earliestFestivalYear
        }
    )
    if ($premiereAfterFestival.Count -gt 0) {
        Add-QualityIssue -List $qualityErrors -Code "premiere_year_after_festival_year" -Message "Films have a Premiere Year later than their earliest Festival Year." -Count $premiereAfterFestival.Count
    }

    $missingPoster = @($films | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.posterUrl) }).Count
    if ($missingPoster -gt 0) {
        Add-QualityIssue -List $qualityWarnings -Code "missing_poster" -Message "Films missing poster artwork." -Count $missingPoster
    }

    $missingTmdb = @($films | Where-Object {
        $tmdbId = ConvertTo-OptionalInt $_.tmdbId
        $null -eq $tmdbId -or $tmdbId -le 0
    }).Count
    if ($missingTmdb -gt 0) {
        Add-QualityIssue -List $qualityWarnings -Code "missing_tmdb" -Message "Films missing TMDb ID." -Count $missingTmdb
    }

    $missingDirector = @($films | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.director) }).Count
    if ($missingDirector -gt 0) {
        Add-QualityIssue -List $qualityWarnings -Code "missing_director" -Message "Films missing director metadata." -Count $missingDirector
    }

    $festivalLimits = @{
        "Academy Awards" = @{ warnMin = 15; warnMax = 25; failMax = 30 }
        "Cannes" = @{ warnMin = 20; warnMax = 45; failMax = 50 }
        "Karlovy Vary" = @{ warnMin = 20; warnMax = 30; failMax = 35 }
        "NYFF" = @{ warnMin = 25; warnMax = 35; failMax = 40 }
        "Sundance" = @{ warnMin = 15; warnMax = 45; failMax = 50 }
        "Taipei Film Festival" = @{ warnMin = 10; warnMax = 20; failMax = 25 }
        "Taipei Golden Horse Film Festival" = @{ warnMin = 3; warnMax = 10; failMax = 15 }
        "Venice" = @{ warnMin = 35; warnMax = 45; failMax = 50 }
    }
    $festivalYearLimitOverrides = @{
        "Venice|2024" = @{ warnMin = 1; warnMax = 45; failMax = 50 }
        "Venice|2026" = @{ warnMin = 1; warnMax = 45; failMax = 50 }
    }

    $selectionCounts = @(
        $selections |
            ForEach-Object {
                $festival = [string](Get-ObjectProperty $_ "festival" "")
                $year = Get-SelectionFestivalYear -Selection $_
                if (-not [string]::IsNullOrWhiteSpace($festival) -and $null -ne $year) {
                    [pscustomobject]@{ key = "$festival|$year"; festival = $festival; year = $year }
                }
            } |
            Group-Object key
    )
    foreach ($group in $selectionCounts) {
        $sample = $group.Group[0]
        if (-not $festivalLimits.ContainsKey($sample.festival)) {
            continue
        }
        $overrideKey = "$($sample.festival)|$($sample.year)"
        $limits = if ($festivalYearLimitOverrides.ContainsKey($overrideKey)) { $festivalYearLimitOverrides[$overrideKey] } else { $festivalLimits[$sample.festival] }
        if ($group.Count -gt $limits.failMax) {
            Add-QualityIssue -List $qualityErrors -Code "festival_count_anomaly" -Message "$($sample.festival) $($sample.year) has $($group.Count) selections, above fail limit $($limits.failMax)." -Count $group.Count
        }
        elseif ($group.Count -lt $limits.warnMin -or $group.Count -gt $limits.warnMax) {
            Add-QualityIssue -List $qualityWarnings -Code "festival_count_warning" -Message "$($sample.festival) $($sample.year) has $($group.Count) selections, outside expected range $($limits.warnMin)-$($limits.warnMax)." -Count $group.Count
        }
    }
}
else {
    Add-QualityIssue -List $qualityWarnings -Code "missing_export" -Message "Web data export was not found at $DataPath." -Count 1
}

if ($UseNotion) {
    if ([string]::IsNullOrWhiteSpace($SelectionsDatabaseId)) {
        Add-QualityIssue -List $qualityErrors -Code "missing_notion_selections_db" -Message "NOTION_SELECTIONS_DATABASE_ID is required for Notion quality checks." -Count 1
    }
    else {
        $notionSelections = @(Import-NotionSelections -DatabaseId $SelectionsDatabaseId)
        $missingFilmRelation = @($notionSelections | Where-Object { @($_.film_relation_ids).Count -eq 0 })
        if ($missingFilmRelation.Count -gt 0) {
            Add-QualityIssue -List $qualityErrors -Code "missing_film_relation" -Message "Selections without Film relation in Notion." -Count $missingFilmRelation.Count
        }

        $notionTaipeiOutOfScope = @($notionSelections | Where-Object { -not (Test-TaipeiSelectionInScope -Selection $_) })
        if ($notionTaipeiOutOfScope.Count -gt 0) {
            Add-QualityIssue -List $qualityErrors -Code "notion_taipei_out_of_scope" -Message "Taipei Film Festival selections outside the approved scope remain active in Notion." -Count $notionTaipeiOutOfScope.Count
        }

        $notionSourceYearMismatch = @($notionSelections | Where-Object { -not (Test-SelectionSourceYearMatches -Selection $_) })
        if ($notionSourceYearMismatch.Count -gt 0) {
            Add-QualityIssue -List $qualityErrors -Code "notion_selection_source_year_mismatch" -Message "Notion selections have a Festival Year that does not match the year in their source URL." -Count $notionSourceYearMismatch.Count
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($FilmsDatabaseId)) {
        $notionFilms = @(Import-NotionCanonicalFilms -DatabaseId $FilmsDatabaseId)
        $duplicateNotionCanonical = @(
            $notionFilms |
                Group-Object canonical_key |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Name) -and $_.Count -gt 1 }
        )
        if ($duplicateNotionCanonical.Count -gt 0) {
            Add-QualityIssue -List $qualityErrors -Code "notion_duplicate_canonical" -Message "Duplicate canonical film keys are present in Notion Films." -Count $duplicateNotionCanonical.Count
        }
    }
}

$status = if ($qualityErrors.Count -gt 0 -or ($StrictWarnings -and $qualityWarnings.Count -gt 0)) { "fail" } else { "pass" }
$result = [pscustomobject]@{
    status = $status
    totals = [pscustomobject]@{
        films = @($films).Count
        selections = @($selections).Count
        errors = $qualityErrors.Count
        warnings = $qualityWarnings.Count
    }
    errors = @($qualityErrors.ToArray())
    warnings = @($qualityWarnings.ToArray())
}

$result | ConvertTo-Json -Depth 8
if ($status -ne "pass") {
    exit 1
}
