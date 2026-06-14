# Festival Tracker

Tracks festival films and records the first time each film becomes legally available online.

Legal availability types:

- `streaming_subscription`
- `streaming_free`
- `digital_rent`
- `digital_buy`
- `authorized_download`
- `authorized_torrent`

The tracker does not monitor piracy indexes, store magnet links, or count theatrical screenings, festival online tickets, TV broadcasts, or physical media.

## Web UI

https://platypus-device.github.io/festival-tracker/

## Core Scope

The tracker uses a restrained high-priority scope. The target annual library size is about 180-250 films after de-duplication.

Current daily sources are kept in `config/festivals.json`. Historical editions are handled by manual backfill configs so the daily workflow does not keep rescanning old archive pages.

Enabled or prepared core sources:

- Academy Awards
- Cannes
- Venice
- Sundance
- Karlovy Vary
- Taipei Film Festival
- NYFF
- Berlinale
- Busan
- Taipei Golden Horse Film Festival

Taiwan is handled as its own region. Mainland China festivals are not included.

Disabled sources remain in `config/festivals.json` until they have a stable official source and a strict high-priority section filter.

Academy Awards uses Wikipedia as a stable source because the official ceremony pages block automated requests. It only imports Best Picture, International Feature Film, and Animated Feature Film. Oscars are archived by `Festival Year`, the same as festival selections.

## Automation

GitHub Actions can be triggered manually from the Actions tab. Pushes to `main` publish the current web bundle only and do not write to Notion.

Scheduled runs:

- Daily at 23:30 UTC: `Availability`.
- Weekly on Monday at 23:45 UTC: `Lineups` with `RespectFestivalWindows`, so only sources whose `lineupWindow` includes the current month are fetched.
- Scheduled and manual sync runs export the web bundle and then run `Test-TrackerDataQuality.ps1` before deployment. `Lineups` runs are followed by an `Availability` pass so new selections get metadata and availability before the quality gate. Pushes still publish the committed web bundle only.
- Notion sync uses a preloaded page index and diff-based updates. Existing non-empty Notion fields are not cleared by empty incoming values, unchanged records are skipped, and existing page covers are not bulk-updated during routine sync.

Workflow modes:

- `Availability`: check pending films for first legal availability.
- `Lineups`: fetch enabled festival lineup sources.
- `All`: run both lineup and availability checks.

## Required GitHub Secrets

- `NOTION_TOKEN`
- `TMDB_BEARER_TOKEN`
- `NOTION_CANONICAL_FILMS_DATABASE_ID`
- `NOTION_SELECTIONS_DATABASE_ID`
- `NOTION_EVENTS_DATABASE_ID`

Optional:

- `NOTION_FILMS_DATABASE_ID` legacy fallback for the old single-table selections database name.
- `OMDB_API_KEY`
- `WATCHMODE_API_KEY`

Current Notion model:

- `Films`: canonical film records and metadata.
- `Festival Selections`: festival-specific lineup records. In code and secrets this is `NOTION_SELECTIONS_DATABASE_ID`.
- `First Legal Availability Events`: first legal availability events.

`Festival Selections` still contains some legacy film metadata columns from the old single-table model. Treat `Films` as the source of truth for title metadata, director, TMDb/IMDb IDs, poster, overview, ratings, and tracking status.

TMDb and IMDb remain the primary metadata sources. Official festival data may fill a missing field when it is clearly available; currently Taipei Film Festival official poster URLs are used only as a poster fallback and are marked with `Metadata Source = official:taipeiff`.

Year fields are intentionally split:

- `Festival Year`: festival edition year from each selection.
- `Premiere Year`: browse/filter year for the web UI.
- `Release Year`: TMDb commercial or ordinary release year.
- `Film Year`: legacy compatibility field; do not write TMDb release years here.
- `Year Source`: provenance for `Premiere Year`, such as `official_festival`, `tmdb_premiere`, `festival_year_fallback`, or `oscars_eligibility`.

## Local Commands

Run the full tracker against Notion:

```powershell
.\scripts\Invoke-FestivalTracker.ps1 -Mode All -UseNotion
```

Ensure or update Notion schema explicitly after a schema change:

```powershell
.\scripts\Invoke-FestivalTracker.ps1 -Mode Availability -UseNotion -EnsureNotionSchema
```

Export Notion data for the web UI:

```powershell
.\scripts\Export-TrackerData.ps1 -UseNotion
```

Check and repair duplicate canonical Films after a migration or a large lineup import:

```powershell
.\scripts\Reconcile-NotionFilms.ps1
.\scripts\Reconcile-NotionFilms.ps1 -Apply -ArchiveDuplicates
```

Archive selections that are outside the current restrained scope:

```powershell
.\scripts\Archive-OutOfScopeSelections.ps1
.\scripts\Archive-OutOfScopeSelections.ps1 -Apply -ArchiveOrphanFilms
```

Run data quality checks:

```powershell
.\scripts\Test-TrackerDataQuality.ps1 -DataPath .\web\data\tracker-data.json
.\scripts\Test-TrackerDataQuality.ps1 -UseNotion -DataPath .\web\data\tracker-data.json
```

Dry-run and apply missing metadata repairs:

```powershell
.\scripts\Repair-MissingMetadata.ps1 -UseNotion -Limit 20
.\scripts\Repair-MissingMetadata.ps1 -UseNotion -Apply -Limit 20
```

Dry-run and apply year metadata repairs:

```powershell
.\scripts\Repair-YearMetadata.ps1
.\scripts\Repair-YearMetadata.ps1 -Apply
.\scripts\Repair-YearMetadata.ps1 -UseNotion
.\scripts\Repair-YearMetadata.ps1 -UseNotion -Apply
```

Backfill a historical year after a dry-run:

```powershell
.\scripts\Invoke-FestivalTracker.ps1 -Mode Lineups -ConfigPath .\config\backfills\2025.json -DryRun
.\scripts\Invoke-FestivalTracker.ps1 -Mode Lineups -ConfigPath .\config\backfills\2025.json -UseNotion
.\scripts\Export-TrackerData.ps1 -UseNotion
```

Start the local web UI:

```powershell
node .\web\server.js
```

Run tests:

```powershell
.\tests\Run-Tests.ps1
```

## Matching Diagnostics

`Tracking Status` is the only workflow status:

- `pending`: no legal online availability has been found yet.
- `available_found`: the first legal online availability event has been recorded.
- `needs_review`: automation cannot safely continue for this item.

Low-confidence TMDb/IMDb matches are exported as diagnostics. They are useful for maintenance, but they are not shown as a main review queue in the web UI. The export also reports missing poster, missing TMDb ID, missing director, and duplicate canonical key counts with capped issue lists for maintenance.
