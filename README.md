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

The tracker does not monitor piracy indexes, store magnet links, or count theatrical screenings, festival online tickets, TV broadcasts, or physical media.

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

## Local Commands

```powershell
# Run full tracker against Notion
.\scripts\Invoke-FestivalTracker.ps1 -Mode All -UseNotion

# Ensure Notion schema before a sync
.\scripts\Invoke-FestivalTracker.ps1 -Mode Availability -UseNotion -EnsureNotionSchema

# Export web data
.\scripts\Export-TrackerData.ps1 -UseNotion

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
