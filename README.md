# Festival Tracker

Tracks festival and award films, enriches their metadata and ratings, and records when this tracker first finds each film in the YTS catalog.

Live site: https://platypus-device.github.io/festival-tracker/

## What It Tracks

YTS checks cover every film with a valid IMDb ID and an active festival or award selection, regardless of its historical legal-availability status. Every unchecked film receives an initial check regardless of its year. After a successful not-found result, films premiered in the current or previous year are rechecked daily; older films are rechecked every seven Asia/Shanghai calendar days. The recent-year window rolls automatically each January. Premiere year is used first, with legacy film year as a fallback; unknown or future years keep daily checks. Confirmed listings are retained without routine rechecks.

The website has YTS listed, All films, and Discovery log views. The log uses the first observation recorded by this tracker, which is not the film's YTS upload date. Cards keep the original festival and IMDb/TMDb rating formats. Only All films shows status labels, with the green YTS label reusing the former Available style; YTS listed omits the redundant label. Observation dates appear in the log rather than under film cards.

Legal provider checks and first-availability event creation are retired. Historical Notion Events and availability properties are preserved, but normal syncs and exports neither read nor update them. The production model requires only Canonical Films and Selections. Legacy availability helpers remain for explicit archive maintenance and regression tests; `Export-TrackerData.ps1 -IncludeLegacyAvailability` opts into the old export for those uses.

Only successful queries update the last-check timestamp. A failed query leaves its film due for the next daily task, including a failed weekly check; the next successful query starts a new daily or weekly interval. Results, observation dates, and resource metadata live in Canonical Films in Notion. The website displays the exported snapshot and makes no YTS API requests.

Checks use one request at a time with at least three seconds between request starts, deduplicate IMDb IDs, and save each successful result immediately. HTTP 403/429 or three consecutive failures stop the remaining checks without replacing earlier results. A 25-minute run budget defers any unfinished work to a later run; there is no fixed 100-film cap.

## Sources

Festival sources are configured in `config/festivals.json`, with historical backfills in `config/backfills/`.

The restrained core scope currently covers major festival and awards sources including Academy Awards, Cannes, Venice, Sundance, Karlovy Vary, Taipei Film Festival, NYFF, Berlinale, Busan, and Taipei Golden Horse Film Festival.

## Automation

GitHub Actions powers the tracker:

- Pushes to `main` publish the committed web bundle.
- Daily schedule refreshes metadata and ratings, then checks due YTS listings.
- Weekly schedule refreshes active lineup windows, then metadata, ratings, and due YTS listings.
- Manual runs can use `Metadata`, `Lineups`, or `All`. The CLI's old `Availability` mode is a compatibility alias for `Metadata`; it no longer checks legal providers.

Scheduled and manual syncs write to Notion, export `web/data/tracker-data.json`, run quality checks, and deploy GitHub Pages only after the checks pass.
Push deployments also run the due YTS checks before exporting, so a deployment and the daily schedule share the same persisted check dates.

## Local Commands

```powershell
# Run full tracker against Notion
.\scripts\Invoke-FestivalTracker.ps1 -Mode All -UseNotion

# Ensure Notion schema before a sync
.\scripts\Invoke-FestivalTracker.ps1 -Mode Metadata -UseNotion -EnsureNotionSchema

# Export web data
.\scripts\Export-TrackerData.ps1 -UseNotion

# Preview or run the Notion-backed YTS catalog sync
.\scripts\Sync-YtsCatalog.ps1 -DryRun
.\scripts\Sync-YtsCatalog.ps1

# Run quality checks
.\scripts\Test-TrackerDataQuality.ps1 -UseNotion -DataPath .\web\data\tracker-data.json

# Start local web UI
node .\web\server.js

# Run tests
.\tests\Run-Tests.ps1
```

## Required Secrets

- `NOTION_TOKEN`
- `TMDB_BEARER_TOKEN`
- `NOTION_CANONICAL_FILMS_DATABASE_ID`
- `NOTION_SELECTIONS_DATABASE_ID`

Optional: `OMDB_API_KEY`, `TMDB_API_KEY`, and legacy `NOTION_FILMS_DATABASE_ID`. Keep `NOTION_EVENTS_DATABASE_ID` only for explicit historical maintenance; it is not required by normal production runs.
