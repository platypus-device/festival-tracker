param(
    [string]$DataPath = ".\web\data\tracker-data.json",
    [switch]$UseNotion,
    [string]$FilmsDatabaseId = $env:NOTION_CANONICAL_FILMS_DATABASE_ID,
    [string]$SelectionsDatabaseId = $env:NOTION_SELECTIONS_DATABASE_ID,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1") -Force

function Get-RepairTargetYears {
    param(
        [Parameter(Mandatory = $true)][object]$Film,
        [object[]]$FestivalYears = @()
    )

    $validFestivalYears = @(
        $FestivalYears |
            ForEach-Object { ConvertTo-OptionalInt $_ } |
            Where-Object { $null -ne $_ -and $_ -gt 0 } |
            Sort-Object
    )
    $minFestivalYear = if (@($validFestivalYears).Count -gt 0) { [int]$validFestivalYears[0] } else { $null }
    $premiereYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "premiereYear" (Get-ObjectProperty $Film "premiere_year" $null))
    $releaseYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "releaseYear" (Get-ObjectProperty $Film "release_year" $null))
    $filmYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "filmYear" (Get-ObjectProperty $Film "film_year" $null))
    $festival = [string](Get-ObjectProperty $Film "festival" "")
    if ([string]::IsNullOrWhiteSpace($festival) -and $null -ne $Film.PSObject.Properties["selections"]) {
        $festival = [string](@($Film.selections | ForEach-Object { $_.festival } | Where-Object { $_ } | Select-Object -First 1))
    }

    $targetReleaseYear = $releaseYear
    if ($null -eq $targetReleaseYear -and $null -ne $filmYear -and $null -ne $minFestivalYear -and $filmYear -gt $minFestivalYear) {
        $targetReleaseYear = $filmYear
    }
    if ($null -eq $targetReleaseYear -and $null -ne $premiereYear -and $null -ne $minFestivalYear -and $premiereYear -gt $minFestivalYear) {
        $targetReleaseYear = $premiereYear
    }

    $targetPremiereYear = $premiereYear
    $yearSource = [string](Get-ObjectProperty $Film "yearSource" (Get-ObjectProperty $Film "year_source" ""))
    if ($null -eq $targetPremiereYear -or ($null -ne $minFestivalYear -and $targetPremiereYear -gt $minFestivalYear)) {
        if ($null -ne $filmYear -and ($null -eq $minFestivalYear -or $filmYear -le $minFestivalYear)) {
            $targetPremiereYear = $filmYear
            $yearSource = "official_festival"
        }
        elseif ($festival -eq "Academy Awards" -and $null -ne $minFestivalYear -and $minFestivalYear -gt 1) {
            $targetPremiereYear = $minFestivalYear - 1
            $yearSource = "oscars_eligibility"
        }
        elseif ($null -ne $minFestivalYear) {
            $targetPremiereYear = $minFestivalYear
            $yearSource = "festival_year_fallback"
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($yearSource)) {
        $yearSource = "official_festival"
    }

    [pscustomobject]@{
        premiereYear = $targetPremiereYear
        releaseYear = $targetReleaseYear
        filmYear = $targetPremiereYear
        yearSource = $yearSource
        needsRepair = (
            ($null -ne $targetPremiereYear -and $targetPremiereYear -ne $premiereYear) -or
            ($null -ne $targetReleaseYear -and $targetReleaseYear -ne $releaseYear) -or
            ($null -ne $targetPremiereYear -and $targetPremiereYear -ne $filmYear) -or
            (-not [string]::IsNullOrWhiteSpace($yearSource) -and $yearSource -ne [string](Get-ObjectProperty $Film "yearSource" (Get-ObjectProperty $Film "year_source" "")))
        )
    }
}

function New-YearRepairRow {
    param(
        [Parameter(Mandatory = $true)][object]$Film,
        [Parameter(Mandatory = $true)][object]$Target,
        [object[]]$FestivalYears = @()
    )

    [pscustomobject]@{
        title = [string](Get-ObjectProperty $Film "title" (Get-ObjectProperty $Film "Film Title" ""))
        director = [string](Get-ObjectProperty $Film "director" "")
        currentPremiereYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "premiereYear" (Get-ObjectProperty $Film "premiere_year" $null))
        currentFilmYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "filmYear" (Get-ObjectProperty $Film "film_year" $null))
        currentReleaseYear = ConvertTo-OptionalInt (Get-ObjectProperty $Film "releaseYear" (Get-ObjectProperty $Film "release_year" $null))
        targetPremiereYear = $Target.premiereYear
        targetFilmYear = $Target.filmYear
        targetReleaseYear = $Target.releaseYear
        yearSource = $Target.yearSource
        festivalYears = (@($FestivalYears | Sort-Object -Unique) -join ",")
    }
}

$repairs = New-Object System.Collections.Generic.List[object]

if ($UseNotion) {
    if ([string]::IsNullOrWhiteSpace($FilmsDatabaseId) -or [string]::IsNullOrWhiteSpace($SelectionsDatabaseId)) {
        throw "Set NOTION_CANONICAL_FILMS_DATABASE_ID and NOTION_SELECTIONS_DATABASE_ID, or pass -FilmsDatabaseId and -SelectionsDatabaseId."
    }

    $films = @(Import-NotionCanonicalFilms -DatabaseId $FilmsDatabaseId)
    $selections = @(Import-NotionSelections -DatabaseId $SelectionsDatabaseId)
    $selectionsByFilmPageId = @{}
    foreach ($selection in $selections) {
        foreach ($filmPageId in @($selection.film_relation_ids)) {
            if (-not $selectionsByFilmPageId.ContainsKey($filmPageId)) {
                $selectionsByFilmPageId[$filmPageId] = New-Object System.Collections.Generic.List[object]
            }
            $selectionsByFilmPageId[$filmPageId].Add($selection) | Out-Null
        }
    }

    foreach ($film in $films) {
        $filmSelections = if ($selectionsByFilmPageId.ContainsKey($film.notion_page_id)) { @($selectionsByFilmPageId[$film.notion_page_id].ToArray()) } else { @() }
        $festivalYears = @($filmSelections | ForEach-Object { ConvertTo-OptionalInt (Get-ObjectProperty $_ "festival_year" (Get-ObjectProperty $_ "year" $null)) } | Where-Object { $null -ne $_ })
        $target = Get-RepairTargetYears -Film $film -FestivalYears $festivalYears
        if (-not $target.needsRepair) { continue }

        $repairs.Add((New-YearRepairRow -Film $film -Target $target -FestivalYears $festivalYears)) | Out-Null
        if ($Apply) {
            $properties = @{
                "Premiere Year" = @{ number = $target.premiereYear }
                "Film Year" = @{ number = $target.filmYear }
                "Year Source" = New-RichTextProperty $target.yearSource
            }
            if ($null -ne $target.releaseYear) {
                $properties["Release Year"] = @{ number = $target.releaseYear }
            }
            Invoke-NotionRequest -Method "PATCH" -Path "/v1/pages/$($film.notion_page_id)" -Body @{ properties = $properties } | Out-Null
        }
    }
}
else {
    if (-not (Test-Path -LiteralPath $DataPath)) {
        throw "Data file not found: $DataPath"
    }

    $payload = Get-Content -LiteralPath $DataPath -Raw | ConvertFrom-Json
    foreach ($film in @($payload.films)) {
        $festivalYears = @($film.selections | ForEach-Object { ConvertTo-OptionalInt (Get-ObjectProperty $_ "festivalYear" $null) } | Where-Object { $null -ne $_ })
        $target = Get-RepairTargetYears -Film $film -FestivalYears $festivalYears
        if (-not $target.needsRepair) { continue }

        $repairs.Add((New-YearRepairRow -Film $film -Target $target -FestivalYears $festivalYears)) | Out-Null
        if ($Apply) {
            Set-RecordProperty -Record $film -Name "premiereYear" -Value $target.premiereYear
            Set-RecordProperty -Record $film -Name "filmYear" -Value $target.filmYear
            Set-RecordProperty -Record $film -Name "releaseYear" -Value $target.releaseYear
            Set-RecordProperty -Record $film -Name "yearSource" -Value $target.yearSource
        }
    }

    if ($Apply) {
        $premiereYears = @(
            $payload.films |
                ForEach-Object { ConvertTo-OptionalInt (Get-ObjectProperty $_ "premiereYear" $null) } |
                Where-Object { $null -ne $_ } |
                Sort-Object -Descending -Unique
        )
        Set-RecordProperty -Record $payload -Name "years" -Value $premiereYears
        Set-RecordProperty -Record $payload -Name "premiereYears" -Value $premiereYears
        Set-RecordProperty -Record $payload -Name "filmYears" -Value $premiereYears
        $payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $DataPath -Encoding UTF8
    }
}

[pscustomobject]@{
    mode = if ($Apply) { "apply" } else { "dry_run" }
    count = $repairs.Count
    repairs = @($repairs.ToArray())
} | ConvertTo-Json -Depth 8
