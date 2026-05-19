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

## Current Scope

Enabled lineup sources:

- Cannes
- Venice
- Sundance
- Karlovy Vary
- Taipei Film Festival

Taiwan is handled as its own region. Mainland China festivals are not included.

## Automation

GitHub Actions runs daily and can also be triggered manually from the Actions tab.

Workflow modes:

- `Availability`: check pending films for first legal availability.
- `Lineups`: fetch enabled festival lineup sources.
- `All`: run both lineup and availability checks.

## Required GitHub Secrets

- `NOTION_TOKEN`
- `TMDB_BEARER_TOKEN`
- `NOTION_FILMS_DATABASE_ID`
- `NOTION_EVENTS_DATABASE_ID`

Optional:

- `WATCHMODE_API_KEY`

## Local Commands

Run the full tracker against Notion:

```powershell
.\scripts\Invoke-FestivalTracker.ps1 -Mode All -UseNotion
```

Export Notion data for the web UI:

```powershell
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

## Review Queue

Films enter `Needs Review` when the tracker cannot confidently match the source title to TMDb/IMDb or when source metadata is incomplete.

Review those rows before trusting any availability event for the film.
