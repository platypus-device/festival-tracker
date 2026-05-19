# Festival Legal Availability Tracker

Tracks one event for each festival film: the first time the film becomes legally available online anywhere.

Legal availability types:

- `streaming_subscription`
- `streaming_free`
- `digital_rent`
- `digital_buy`
- `authorized_download`
- `authorized_torrent`

The tracker does not monitor piracy indexes, does not store magnet links, and does not treat theatrical screenings, festival online tickets, TV broadcasts, or physical media as availability.

## Current Scope

Enabled lineup sources:

- Cannes
- Venice
- Sundance
- Karlovy Vary
- Taipei Film Festival

Disabled or experimental sources remain in `config/festivals.json` with `enabled: false`. This includes Oscars and first-batch targets that still need a verified parser or stable official source, such as Berlinale and NYFF.

Taiwan is handled as its own region. Mainland China festivals are not included.

## Notion Schema

The project uses two Notion databases:

- `Festival Films`: imported lineup entries, TMDb/IMDb match data, poster URL, overview, rating, and tracking status.
- `First Legal Availability Events`: one row per first legal availability event.

Event rows keep the text `Film Tracker ID` as a stable script key and also include a `Film` relation back to the matching `Festival Films` page when Notion database IDs are configured.

## Daily Automation

The GitHub Actions schedule runs `Availability` mode by default. That means it checks only films whose `Tracking Status` is still `pending`.

Lineup fetching is manual by default:

```powershell
./scripts/Invoke-FestivalTracker.ps1 -Mode Lineups -UseNotion -RespectFestivalWindows
```

Run both lineup and availability checks manually:

```powershell
./scripts/Invoke-FestivalTracker.ps1 -Mode All -UseNotion -RespectFestivalWindows
```

Run availability only:

```powershell
./scripts/Invoke-FestivalTracker.ps1 -Mode Availability -UseNotion
```

Use `-DryRun` to preview local changes without writing state files or syncing Notion:

```powershell
./scripts/Invoke-FestivalTracker.ps1 -Mode Lineups -UseNotion -RespectFestivalWindows -DryRun
```

## Web Viewer

The `web` directory contains a read-only browser UI for the tracker. Notion remains the source of truth; the UI reads an exported JSON file.

Export data from Notion:

```powershell
.\scripts\Export-TrackerData.ps1 -UseNotion
```

Start the local web server:

```powershell
node .\web\server.js
```

Open:

```text
http://127.0.0.1:4173
```

The viewer includes:

- `Available`: films with a first legal availability event.
- `All Films`: the full imported festival list.
- `Review Queue`: films marked as needing review.
- `Recent Finds`: first legal availability events.

## GitHub Pages Deployment

The GitHub Actions workflow can publish the `web` directory to GitHub Pages after each sync.

Required repository setup:

1. Push this project to a GitHub repository.
2. In repository settings, add Actions secrets:
   - `NOTION_TOKEN`
   - `TMDB_BEARER_TOKEN`
   - `NOTION_FILMS_DATABASE_ID`
   - `NOTION_EVENTS_DATABASE_ID`
   - Optional: `TMDB_API_KEY`, `WATCHMODE_API_KEY`
3. In repository settings, open Pages and set Source to `GitHub Actions`.
4. Run the workflow manually once from the Actions tab.

The scheduled workflow runs availability checks daily, exports `web/data/tracker-data.json`, and deploys the static site to GitHub Pages.

## Required Environment Variables

- `TMDB_BEARER_TOKEN`
- `NOTION_TOKEN`
- `NOTION_FILMS_DATABASE_ID`
- `NOTION_EVENTS_DATABASE_ID`

Optional:

- `WATCHMODE_API_KEY`

## Review Policy

Rows enter `Needs Review` when the script cannot confidently match the film to TMDb/IMDb or when source data is incomplete. Review those rows before trusting an availability event.

When adding a new festival, prefer a festival-specific parser and run it in dry-run mode first. Do not enable generic parsers for scheduled runs until the result count and sample rows have been manually checked.
