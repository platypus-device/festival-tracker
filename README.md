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

Academy Awards parsing is implemented for Best Picture, International Feature Film, and Animated Feature Film, but the official ceremony page is currently disabled because it blocks automated requests.

## Automation

GitHub Actions runs daily and can also be triggered manually from the Actions tab.
Pushes to `main` publish the current web bundle only; scheduled and manual runs perform Notion sync before deployment.

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

- `OMDB_API_KEY`
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

Low-confidence TMDb/IMDb matches are exported as diagnostics. They are useful for maintenance, but they are not shown as a main review queue in the web UI.
