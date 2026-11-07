$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\src\FestivalTracker.psm1") -Force

& (Get-Module FestivalTracker) {
    $saved = @{}
    $names = @("Get-EnvValue", "Import-NotionCanonicalFilms", "Import-NotionSelections", "Import-NotionEvents", "Update-FilmMatches", "Update-FilmImdbDatasetRatings", "Update-FilmOmdbRatings", "Add-FirstAvailabilityEvents", "Sync-NotionState", "Write-JsonFile", "Read-JsonFile", "Update-NotionDatabaseSchemaProperties", "Get-NotionDatabasePages", "Sync-NotionCanonicalFilm")
    foreach ($name in $names) { $saved[$name] = (Get-Command $name).ScriptBlock }
    function Assert-Catalog { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw "FAIL: $Message" }; Write-Host "PASS: $Message" }
    try {
        $script:CatalogCalls = New-Object System.Collections.Generic.List[string]
        $script:CatalogFilm = [pscustomobject]@{ id = "film"; title = "Test Film"; original_title = "Test Film"; notion_page_id = "film-page"; canonical_key = "imdb:tt1001"; imdb_id = "tt1001"; tracking_status = "available_found"; first_available_date = "2020-01-01" }
        function script:Get-EnvValue { param($Name) if ($Name -eq "NOTION_CANONICAL_FILMS_DATABASE_ID") { return "films-db" }; if ($Name -eq "NOTION_SELECTIONS_DATABASE_ID") { return "selections-db" }; return "" }
        function script:Read-JsonFile { param($Path, $Default) if ($Path -notlike "*festivals.json") { throw "Unexpected local fallback/config read: $Path" }; return [pscustomobject]@{ festivals = @() } }
        function script:Import-NotionCanonicalFilms { param($DatabaseId) return @($script:CatalogFilm) }
        function script:Import-NotionSelections { param($DatabaseId) return @([pscustomobject]@{ id = "selection"; film_relation_ids = @("film-page") }) }
        function script:Import-NotionEvents { throw "Retired Events database must not be read" }
        function script:Add-FirstAvailabilityEvents { throw "Retired legal provider checks must not run" }
        function script:Update-FilmMatches { param($Films) $script:CatalogCalls.Add("metadata"); return $Films }
        function script:Update-FilmImdbDatasetRatings { param($Films, $StateDir) $script:CatalogCalls.Add("imdb"); return $Films }
        function script:Update-FilmOmdbRatings { param($Films, $MaxUpdates) $script:CatalogCalls.Add("omdb"); return $Films }
        function script:Write-JsonFile { param($Path, $Value) if ($Path -notlike "*films.json") { throw "Historical event archive must not be written" }; $script:CatalogCalls.Add("cache") }
        function script:Sync-NotionState { param($Films, [switch]$EnsureNotionSchema, [switch]$CatalogOnly) if (-not $CatalogOnly) { throw "Catalog-only Notion sync is required" }; $script:CatalogCalls.Add("notion") }
        foreach ($mode in @("Metadata", "Availability")) {
            $script:CatalogCalls.Clear()
            $result = Invoke-FestivalTracker -Mode $mode -UseNotion -EnsureNotionSchema
            Assert-Catalog ($result.films_count -eq 1 -and $result.new_events_count -eq 0) "$mode refreshes active canonical films without creating availability events"
            Assert-Catalog (($script:CatalogCalls -join ",") -eq "metadata,imdb,omdb,cache,notion") "$mode preserves metadata and rating updates and uses catalog-only persistence"
        }
        $properties = ConvertTo-NotionCanonicalFilmProperties -Film $script:CatalogFilm -CatalogOnly
        Assert-Catalog (-not $properties.ContainsKey("Tracking Status") -and -not $properties.ContainsKey("First Available Date") -and -not $properties.ContainsKey("Last Checked") -and -not $properties.ContainsKey("Authorized Source URLs")) "catalog-only canonical patches leave historical availability properties untouched"
        $script:CatalogSchemaLabels = New-Object System.Collections.Generic.List[string]
        function script:Update-NotionDatabaseSchemaProperties { param($DatabaseId, $DatabaseLabel, $DesiredProperties) $script:CatalogSchemaLabels.Add($DatabaseLabel) }
        Ensure-NotionThreeTableSchema -FilmsDatabaseId "films-db" -SelectionsDatabaseId "selections-db" -CatalogOnly
        Assert-Catalog (($script:CatalogSchemaLabels -join ",") -eq "Films,Selections") "catalog schema management requires only Films and Selections"
        function script:Import-NotionCanonicalFilms { throw "Notion unavailable" }
        $script:CatalogCalls.Clear()
        $failed = $false
        try { Invoke-FestivalTracker -Mode Metadata -UseNotion | Out-Null } catch { $failed = $_.Exception.Message -like "*refusing*local fallback*" }
        Assert-Catalog ($failed -and $script:CatalogCalls.Count -eq 0) "failed production imports cannot fall back to local data or write to Notion"
        Set-Item -Path Function:script:Sync-NotionState -Value $saved["Sync-NotionState"]
        function script:Get-NotionDatabasePages { param($DatabaseId) if ($DatabaseId -ne "films-db") { throw "Unexpected database read: $DatabaseId" }; return @() }
        function script:Sync-NotionCanonicalFilm { param($Film, $DatabaseId, $Context, [switch]$CatalogOnly) if (-not $CatalogOnly) { throw "Historical availability fields must be excluded" }; return $Film }
        $catalogSync = Sync-NotionState -Films @($script:CatalogFilm) -NewEvents @([pscustomobject]@{ id = "historical-event" }) -ExistingEvents @([pscustomobject]@{ id = "historical-event" }) -CatalogOnly -EnsureNotionSchema
        Assert-Catalog ($catalogSync.films.Count -eq 1 -and $catalogSync.events.Count -eq 0) "actual catalog persistence works without Events credentials and ignores historical event inputs"
    }
    finally {
        foreach ($name in $saved.Keys) { Set-Item -Path "Function:script:$name" -Value $saved[$name] }
        Remove-Variable -Scope Script -Name CatalogCalls, CatalogFilm, CatalogSchemaLabels -ErrorAction SilentlyContinue
    }
}
