# Festival Tracker Agent Guide

## Purpose
Festival Tracker tracks films selected by major festivals and awards, enriches film metadata, records the first time each film becomes legally available online, and publishes a static browsing UI through GitHub Pages.

Live site:
https://platypus-device.github.io/festival-tracker/

## Architecture
- `src/FestivalTracker.psm1`: main PowerShell module. It contains lineup parsers, metadata enrichment, availability checks, Notion sync, Notion schema management, and repair helpers.
- `scripts/Invoke-FestivalTracker.ps1`: main tracker entrypoint. It delegates to `Invoke-FestivalTracker` in the module.
- `scripts/Export-TrackerData.ps1`: exports production Notion state into `web/data/tracker-data.json` for the frontend.
- `scripts/Test-TrackerDataQuality.ps1`: validates exported data and optional Notion state before deployment.
- `config/festivals.json`: enabled festivals, source URLs, parsers, section scopes, and lineup windows.
- `config/authorized_sources.json`: allowlist for official/download/torrent availability sources.
- `web/`: static frontend deployed as the GitHub Pages artifact.
- `web/data/tracker-data.json`: generated frontend data consumed by `web/app.js`.
- `.github/workflows/tracker.yml`: GitHub Actions sync, export, quality check, and Pages deployment.
- `.tracker/`: ignored local fallback/cache for development and tests when `-UseNotion` is not supplied. It is not the production source of truth.

## Data Flow
```text
config/festivals.json
        -> scripts/Invoke-FestivalTracker.ps1
        -> src/FestivalTracker.psm1
        -> Notion production state
        -> scripts/Export-TrackerData.ps1
        -> web/data/tracker-data.json
        -> web/index.html + web/app.js + web/styles.css
        -> GitHub Pages
```

## Tracker Modes
- `Lineups`: fetches configured festival sources, parses lineup records, and merges them into the current film state.
- `Availability`: refreshes metadata and ratings, checks legal availability providers/sources, and creates first-availability events.
- `All`: runs lineup sync and availability sync in one pass.

Use `-UseNotion` for normal project work. Production state lives in Notion. Without `-UseNotion`, the tracker reads and writes `.tracker/films.json` and `.tracker/events.json` only as a local fallback for development and tests.

## Notion-First State Model
The project is designed to run without this local machine in the production loop. GitHub Actions reads and writes Notion using repository secrets, exports `web/data/tracker-data.json`, and deploys the static `web/` artifact to GitHub Pages.

The current workflow uses the three-table Notion model:
- Canonical Films: one row per canonical film.
- Selections: festival/award selection rows related to canonical films.
- Events: first legal availability events related to canonical films.

Legacy `NOTION_FILMS_DATABASE_ID` support still exists, but new work should assume the three-table model unless the task explicitly concerns migration or legacy compatibility. Do not treat `.tracker/films.json` or `.tracker/events.json` as authoritative project data.

Required production secrets:
- `NOTION_TOKEN`
- `TMDB_BEARER_TOKEN`
- `NOTION_CANONICAL_FILMS_DATABASE_ID`
- `NOTION_SELECTIONS_DATABASE_ID`
- `NOTION_EVENTS_DATABASE_ID`

Optional:
- `TMDB_API_KEY`
- `OMDB_API_KEY`
- `WATCHMODE_API_KEY`
- legacy `NOTION_FILMS_DATABASE_ID`

## GitHub Actions And Deployment
Deployment is handled by `.github/workflows/tracker.yml`.

- Push to `main`: repair year metadata in Notion, export web data from Notion, run quality checks, prepare `web/build-meta.*`, and deploy `web/` to GitHub Pages.
- Daily scheduled run: defaults to `Availability`.
- Weekly scheduled run: runs `Lineups` with festival windows respected, then runs `Availability`.
- Manual workflow dispatch: supports `Availability`, `Lineups`, or `All`.

`web/build-meta.js` is generated during deployment with the current commit SHA. The frontend uses it as the cache version for `web/data/tracker-data.json`. The frontend never talks to Notion directly; it only reads the exported static JSON.

When editing `web/app.js` or `web/styles.css`, update the query version in `web/index.html` so deployed users do not keep stale cached assets.

## Local Commands
Run full tracker against Notion:
```powershell
.\scripts\Invoke-FestivalTracker.ps1 -Mode All -UseNotion
```

Run availability only and ensure Notion schema:
```powershell
.\scripts\Invoke-FestivalTracker.ps1 -Mode Availability -UseNotion -EnsureNotionSchema
```

Export frontend data from Notion:
```powershell
.\scripts\Export-TrackerData.ps1 -UseNotion
```

Run data quality checks:
```powershell
.\scripts\Test-TrackerDataQuality.ps1 -UseNotion -DataPath .\web\data\tracker-data.json
```

Run regression tests:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

Start local frontend with Node:
```powershell
node .\web\server.js
```

Fallback local frontend without Node:
```powershell
python -m http.server 4317 --bind 127.0.0.1 --directory ".\web"
```

Open:
```text
http://127.0.0.1:4317/
```

## Frontend Notes
- `web/index.html` contains the static shell and versioned JS/CSS links.
- `web/app.js` loads `web/data/tracker-data.json`, manages URL state, filters, sorting, grid rendering, event rendering, and the detail panel.
- `web/styles.css` contains all layout and responsive styling.
- `selectionSummaryLabel()` controls card festival/award summary text.
- `primaryRatingLabel()` controls IMDb/TMDb rating label text.
- `filmSelections()` handles current canonical selections plus legacy single-selection records.

For frontend changes, verify:
- Available view loads.
- All Films view loads.
- Finds view loads when relevant.
- Search works.
- Detail panel opens and closes.
- Mobile width around 390px has no clipping, overlap, or unreadable labels.
- Browser console has no relevant errors.

## Test Coverage
`tests/Run-Tests.ps1` covers:
- Festival parsers for Cannes, Venice, Sundance, Oscars, NYFF, KVIFF, Busan, Berlinale, Taipei Film Festival, Golden Horse, and related sources.
- Notion property diff and schema diff behavior.
- Three-table Notion relation and event-link repair logic.
- Export merging for duplicate/canonical film cards.
- Availability event attachment and orphan detection.
- Year repair behavior.
- TMDb provider offer mapping.
- Authorized source allowlist behavior.
- IMDb dataset rating updates.

If changing parsing, export, canonicalization, availability, Notion sync, or year logic, add or update tests before finishing.

## Working Rules
- Do not reset, discard, or overwrite existing user changes unless explicitly asked.
- Keep code changes scoped to the requested behavior.
- Treat `web/data/tracker-data.json` as generated output from Notion. Keep generated data changes separate from code changes when possible.
- When analyzing or reporting current production state, query Notion or the JSON deployed on the live GitHub Pages site. Do not use the repository copy of `web/data/tracker-data.json` as evidence of current production state; it is only a potentially stale development snapshot.
- Treat `.tracker/` as ignored local fallback/cache. Do not rely on it for production behavior or committed project state.
- Prefer structured parsing and existing module helpers over ad hoc string handling.
- For GitHub Pages/frontend cache-sensitive changes, update `web/index.html` asset query versions.
- Before finishing, run the smallest relevant checks. For broad backend changes, run the full test script.
