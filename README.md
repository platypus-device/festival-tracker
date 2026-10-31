# Festival Tracker

Tracks festival films and records the first time each film becomes legally available online.

Live site: https://platypus-device.github.io/festival-tracker/

## What It Tracks

Legal availability types:

- `streaming_subscription`
- `streaming_free`
- `digital_rent`
- `digital_buy`
- `authorized_download`
- `authorized_torrent`

Legal availability does not count theatrical screenings, festival online tickets, TV broadcasts, or physical media. YTS catalog listings are stored separately and never create legal-availability events.

YTS checks cover only films in the website's Available view with a valid IMDb ID and an active festival selection. Unchecked and not-found films are checked once per Asia/Shanghai calendar day; confirmed listings are retained without routine rechecks. Results, observation dates, and resource metadata live in Canonical Films in Notion. The website displays the exported snapshot and makes no YTS API requests.

Checks use one request at a time with at least three seconds between request starts, deduplicate IMDb IDs, and save each successful result immediately. HTTP 403/429 or three consecutive failures stop the remaining checks without replacing earlier results. A 25-minute run budget defers any unfinished work to a later run; there is no fixed 100-film cap.

## Sources

Festival sources are configured in `config/festivals.json`, with historical backfills in `config/backfills/`.

The restrained core scope currently covers major festival and awards sources including Academy Awards, Cannes, Venice, Sundance, Karlovy Vary, Taipei Film Festival, NYFF, Berlinale, Busan, and Taipei Golden Horse Film Festival.

## Automation

GitHub Actions powers the tracker:

- Pushes to `main` publish the committed web bundle.
- Daily schedule runs availability checks.
- Weekly schedule refreshes active lineup windows, then runs availability.
- Manual runs can use `Availability`, `Lineups`, or `All`.

Scheduled and manual syncs write to Notion, export `web/data/tracker-data.json`, run quality checks, and deploy GitHub Pages only after the checks pass.
Push deployments also run the due YTS checks before exporting, so a deployment and the daily schedule share the same persisted check dates.

## Local Commands

```powershell
# Run full tracker against Notion
.\scripts\Invoke-FestivalTracker.ps1 -Mode All -UseNotion

# Ensure Notion schema before a sync
.\scripts\Invoke-FestivalTracker.ps1 -Mode Availability -UseNotion -EnsureNotionSchema

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
- `NOTION_EVENTS_DATABASE_ID`

Optional: `OMDB_API_KEY`, `WATCHMODE_API_KEY`, and legacy `NOTION_FILMS_DATABASE_ID`.
