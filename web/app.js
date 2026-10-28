const state = {
  data: null,
  view: "available",
  search: "",
  festival: "",
  year: "",
  status: "",
  sort: "rating",
};

const validViews = new Set(["available", "all", "events"]);
const validStatuses = new Set(["", "pending", "available_found", "needs_review"]);
const validSorts = new Set(["rating", "available", "festival", "title"]);
let isCompactLayout = window.matchMedia("(max-width: 680px)").matches;

const els = {
  generatedAt: document.querySelector("#generatedAt"),
  metricFilms: document.querySelector("#metricFilms"),
  metricAvailable: document.querySelector("#metricAvailable"),
  metricEvents: document.querySelector("#metricEvents"),
  searchInput: document.querySelector("#searchInput"),
  festivalFilter: document.querySelector("#festivalFilter"),
  yearFilter: document.querySelector("#yearFilter"),
  statusFilter: document.querySelector("#statusFilter"),
  sortSelect: document.querySelector("#sortSelect"),
  viewKicker: document.querySelector("#viewKicker"),
  viewTitle: document.querySelector("#viewTitle"),
  viewMeta: document.querySelector("#viewMeta"),
  filmGrid: document.querySelector("#filmGrid"),
  eventList: document.querySelector("#eventList"),
  detailPanel: document.querySelector("#detailPanel"),
  detailContent: document.querySelector("#detailContent"),
  closeDetail: document.querySelector("#closeDetail"),
  overlay: document.querySelector("#overlay"),
};

const escapeHtml = (value) =>
  String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");

const formatDateTime = (value) => {
  if (!value) return "No export time";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return `Updated ${new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(date)}`;
};

const statusLabel = (status) => {
  if (status === "available_found") return "Available";
  if (status === "needs_review") return "Needs review";
  return "Pending";
};

const statusClass = (status) => {
  if (status === "available_found") return "is-available";
  if (status === "needs_review") return "is-review";
  return "is-pending";
};

const availabilitySummary = (event) => {
  if (!event) return "";
  const date = event.event_date || "Recorded";
  const types = Array.isArray(event.availability_types) ? event.availability_types : [];
  const readableTypes = types.map((type) => type.replaceAll("_", " ")).join(", ");
  return readableTypes ? `${date} - ${readableTypes}` : date;
};

const ratingLabel = (rating) => {
  const value = Number(rating);
  return Number.isFinite(value) && value > 0 ? value.toFixed(1) : "Unrated";
};

const primaryRatingValue = (film) => {
  const imdb = Number(film?.imdbRating);
  if (Number.isFinite(imdb) && imdb > 0) return imdb;
  const tmdb = Number(film?.tmdbRating);
  if (Number.isFinite(tmdb) && tmdb > 0) return tmdb;
  return 0;
};

const ratingSourceRank = (film) => {
  const imdb = Number(film?.imdbRating);
  if (Number.isFinite(imdb) && imdb > 0) return 2;
  const tmdb = Number(film?.tmdbRating);
  if (Number.isFinite(tmdb) && tmdb > 0) return 1;
  return 0;
};

const primaryRatingLabel = (film) => {
  const imdb = Number(film?.imdbRating);
  if (Number.isFinite(imdb) && imdb > 0) return `IMDb ${imdb.toFixed(1)}`;
  const tmdb = Number(film?.tmdbRating);
  if (Number.isFinite(tmdb) && tmdb > 0) return `TMDb ${tmdb.toFixed(1)}`;
  return "Unrated";
};

const viewCopy = {
  available: {
    kicker: "Available",
    title: "First legal availability",
    meta: "films ready to watch",
  },
  all: {
    kicker: "Library",
    title: "Festival selection",
    meta: "tracked films",
  },
  events: {
    kicker: "Events",
    title: "Recent finds",
    meta: "availability events",
  },
};

const filmSelections = (film) => (Array.isArray(film.selections) && film.selections.length > 0 ? film.selections : [
  {
    festival: film.festival,
    section: film.section,
    festivalYear: film.festivalYear || film.year,
    sourceUrl: film.sourceUrl,
  },
]);

const filmBrowseYear = (film) => {
  if (film?.premiereYear) return String(film.premiereYear);
  const fallbackYears = filmSelections(film)
    .map((selection) => Number(selection.festivalYear))
    .filter((year) => Number.isFinite(year) && year > 0)
    .sort((a, b) => a - b);
  return fallbackYears.length > 0 ? String(fallbackYears[0]) : "";
};

const selectionLabel = (selection) =>
  [selection.festival, selection.festivalYear, selection.section].filter(Boolean).join(" - ");

const selectionSummaryLabel = (film) => {
  const selections = filmSelections(film);
  const festivals = [...new Set(selections.map((selection) => selection.festival).filter(Boolean))];
  const shortFestivals = festivals.map(shortFestivalLabel);
  if (shortFestivals.length > 1) return shortFestivals.slice(0, 3).join(" / ");
  return shortFestivals[0] || shortFestivalLabel(film.festival) || "Festival";
};

const sectionSummaryLabel = (film) => {
  const selections = filmSelections(film);
  if (selections.length > 1) return `${selections.length} selections`;
  return selections[0]?.section || film.section || "Official selection";
};

const shortFestivalLabel = (festival) => {
  const value = String(festival || "").trim();
  const labels = {
    "Academy Awards": "Oscars",
    "Taipei Golden Horse Film Festival": "Golden Horse",
    "Taipei Film Festival": "Taipei",
    "Karlovy Vary": "KVIFF",
  };
  return labels[value] || value;
};

const posterMarkup = (film) => {
  const title = escapeHtml(film.title || "Untitled");
  if (film.posterUrl) {
    return `<img src="${escapeHtml(film.posterUrl)}" alt="${title} poster" width="342" height="513" loading="lazy" decoding="async" />`;
  }
  return `<div class="poster-fallback">${title}</div>`;
};

function readUrlState() {
  const params = new URLSearchParams(window.location.search);
  const view = params.get("view");
  const status = params.get("status");
  const sort = params.get("sort");
  const search = params.get("q");
  const festival = params.get("festival");
  const year = params.get("year");

  if (validViews.has(view)) state.view = view;
  if (validStatuses.has(status)) state.status = status;
  if (validSorts.has(sort)) state.sort = sort;
  if (typeof search === "string") state.search = search;
  if (typeof festival === "string") state.festival = festival;
  if (typeof year === "string" && /^\d{4}$/.test(year)) state.year = year;
}

function syncControls() {
  els.searchInput.value = state.search;
  els.statusFilter.value = state.status;
  els.sortSelect.value = state.sort;
  els.festivalFilter.value = state.festival;
  els.yearFilter.value = state.year;
}

function writeUrlState() {
  const params = new URLSearchParams();
  if (state.view !== "available") params.set("view", state.view);
  if (state.search) params.set("q", state.search);
  if (state.festival) params.set("festival", state.festival);
  if (state.year) params.set("year", state.year);
  if (state.status) params.set("status", state.status);
  if (state.sort !== "rating") params.set("sort", state.sort);
  const query = params.toString();
  const nextUrl = query ? `${window.location.pathname}?${query}` : window.location.pathname;
  window.history.replaceState(null, "", nextUrl);
}

async function loadData() {
  readUrlState();
  const appScript = document.currentScript || [...document.scripts].find((script) => script.src.includes("app.js"));
  const appVersion = appScript?.src ? new URL(appScript.src, window.location.href).searchParams.get("v") : "";
  const buildVersion = window.FESTIVAL_TRACKER_BUILD?.version || appVersion || String(Date.now());
  const response = await fetch(`./data/tracker-data.json?v=${encodeURIComponent(buildVersion)}`, { cache: "no-store" });
  if (!response.ok) throw new Error(`Data request failed: ${response.status}`);
  state.data = await response.json();
  setupFilters();
  syncControls();
  syncFilterDrawer();
  render();
}

function syncFilterDrawer() {
  const drawer = document.querySelector(".filter-drawer");
  if (!drawer) return;
  isCompactLayout = window.matchMedia("(max-width: 680px)").matches;
  drawer.open = !isCompactLayout;
}

function handleResize() {
  const nextCompactLayout = window.matchMedia("(max-width: 680px)").matches;
  if (nextCompactLayout === isCompactLayout) return;
  syncFilterDrawer();
}

function setupFilters() {
  const totals = state.data.totals || {};
  els.metricFilms.textContent = totals.films ?? 0;
  els.metricAvailable.textContent = totals.available ?? 0;
  els.metricEvents.textContent = totals.events ?? 0;
  els.generatedAt.textContent = formatDateTime(state.data.generatedAt);

  const festivals = [
    ...new Set(
      (Array.isArray(state.data.films) ? state.data.films : [])
        .flatMap((film) => filmSelections(film).map((selection) => selection.festival))
        .filter(Boolean)
    ),
  ].sort((a, b) => String(a).localeCompare(String(b)));
  const years = Array.isArray(state.data.premiereYears)
    ? state.data.premiereYears
    : Array.isArray(state.data.years)
      ? state.data.years
      : [...new Set((state.data.films || []).map((film) => filmBrowseYear(film)).filter(Boolean))].sort((a, b) => Number(b) - Number(a));
  els.festivalFilter.innerHTML = [
    `<option value="">All festivals</option>`,
    ...festivals.map((festival) => `<option value="${escapeHtml(festival)}">${escapeHtml(festival)}</option>`),
  ].join("");
  els.yearFilter.innerHTML = [
    `<option value="">All years</option>`,
    ...years.map((year) => `<option value="${escapeHtml(year)}">${escapeHtml(year)}</option>`),
  ].join("");
}

function filteredFilms() {
  const query = state.search.trim().toLowerCase();
  let films = Array.isArray(state.data.films) ? [...state.data.films] : [];

  if (state.view === "available") {
    films = films.filter((film) => film.trackingStatus === "available_found");
  }
  if (state.festival) {
    films = films.filter((film) => filmSelections(film).some((selection) => selection.festival === state.festival));
  }
  if (state.year) {
    films = films.filter((film) => filmBrowseYear(film) === state.year);
  }
  if (state.status) {
    films = films.filter((film) => film.trackingStatus === state.status);
  }
  if (query) {
    films = films.filter((film) => {
      const haystack = [film.title, film.originalTitle, film.director, film.selectionSummary, ...(film.selectionLabels || [])]
        .filter(Boolean)
        .join(" ")
        .toLowerCase();
      return haystack.includes(query);
    });
  }

  films.sort((a, b) => {
    if (state.sort === "title") return String(a.title || "").localeCompare(String(b.title || ""));
    if (state.sort === "festival") return String(a.festival || "").localeCompare(String(b.festival || ""));
    if (state.sort === "available") return String(b.firstAvailableDate || "").localeCompare(String(a.firstAvailableDate || ""));
    return ratingSourceRank(b) - ratingSourceRank(a) || primaryRatingValue(b) - primaryRatingValue(a);
  });

  return films;
}

function renderViewHeader(count) {
  const copy = viewCopy[state.view] || viewCopy.available;
  els.viewKicker.textContent = copy.kicker;
  els.viewTitle.textContent = copy.title;
  els.viewMeta.textContent = `${count} ${copy.meta}`;
}

function setMode(mode) {
  els.filmGrid.classList.toggle("hidden", mode !== "grid");
  els.eventList.classList.toggle("hidden", mode !== "events");
}

function renderFilmGrid() {
  const films = filteredFilms();
  setMode("grid");
  renderViewHeader(films.length);
  if (films.length === 0) {
    els.filmGrid.innerHTML = `<div class="empty">No films match this view.</div>`;
    return;
  }

  els.filmGrid.innerHTML = films
    .map(
      (film) => `
        <button class="film-card" data-film-id="${escapeHtml(film.id)}">
          <div class="poster">
            ${posterMarkup(film)}
            <span class="status-pill ${escapeHtml(statusClass(film.trackingStatus))}">${escapeHtml(statusLabel(film.trackingStatus))}</span>
            ${ytsCatalogCardMarkup(film)}
          </div>
          <div class="film-meta">
            <h2 class="film-title">${escapeHtml(film.title || "Untitled")}</h2>
            <p class="film-subtitle">${escapeHtml(film.director || "Unknown director")}</p>
            <div class="film-facts film-card-facts">
              <span>${escapeHtml(selectionSummaryLabel(film))}</span>
              <span>${escapeHtml(primaryRatingLabel(film))}</span>
            </div>
          </div>
        </button>
      `
    )
    .join("");

  document.querySelectorAll(".film-card").forEach((card) => {
    card.addEventListener("click", () => {
      const film = state.data.films.find((item) => item.id === card.dataset.filmId);
      if (film) openDetail(film);
    });
  });
}

function findFilmForEvent(event) {
  const films = Array.isArray(state.data.films) ? state.data.films : [];
  const eventId = String(event?.id || "");
  const eventFilmId = String(event?.film_id || "");

  if (eventId) {
    const filmByEventId = films.find((film) => (film.availability || []).some((item) => String(item.id || "") === eventId));
    if (filmByEventId) return filmByEventId;
  }

  if (!eventFilmId) return null;
  return films.find((film) =>
    String(film.id || "") === eventFilmId ||
    filmSelections(film).some((selection) => String(selection.id || "") === eventFilmId)
  ) || null;
}

function renderEvents() {
  const events = Array.isArray(state.data.events) ? [...state.data.events] : [];
  events.sort((a, b) => String(b.event_date || "").localeCompare(String(a.event_date || "")));
  setMode("events");
  renderViewHeader(events.length);
  if (events.length === 0) {
    els.eventList.innerHTML = `<div class="empty">No availability events yet.</div>`;
    return;
  }

  els.eventList.innerHTML = events
    .map(
      (event, index) => {
        const film = findFilmForEvent(event);
        const eventKey = event.id || `${event.film_id || "event"}-${index}`;
        return `
        <article class="event-row${film ? " is-clickable" : ""}" data-event-id="${escapeHtml(eventKey)}"${film ? ` tabindex="0" role="button" aria-label="Open details for ${escapeHtml(event.film_title || "Untitled")}"` : ""}>
          <time>${escapeHtml(event.event_date || "No date")}</time>
          <div>
            <h3>${escapeHtml(event.film_title || "Untitled")}</h3>
            <p>${escapeHtml([event.providers?.join(", "), event.countries?.join(", ")].filter(Boolean).join(" - "))}</p>
          </div>
          <span class="chip">${escapeHtml((event.availability_types || []).join(", "))}</span>
        </article>
      `;
      }
    )
    .join("");

  els.eventList.querySelectorAll(".event-row.is-clickable").forEach((row) => {
    const event = events.find((item, index) => String(item.id || `${item.film_id || "event"}-${index}`) === row.dataset.eventId);
    const film = findFilmForEvent(event);
    if (!film) return;
    row.addEventListener("click", () => openDetail(film));
    row.addEventListener("keydown", (keyboardEvent) => {
      if (keyboardEvent.key !== "Enter" && keyboardEvent.key !== " ") return;
      keyboardEvent.preventDefault();
      openDetail(film);
    });
  });
}

function render() {
  writeUrlState();
  document.querySelectorAll(".tab").forEach((tab) => {
    tab.classList.toggle("active", tab.dataset.view === state.view);
  });
  if (state.view === "events") renderEvents();
  else renderFilmGrid();
}

const ytsCatalogConfig = {
  apiBase: "https://movies-api.accel.li/api/v2/",
  storagePrefix: "festival-tracker:yts:v1:",
  refreshAfterMs: 24 * 60 * 60 * 1000,
  timeoutMs: 8000,
};
const ytsCatalogResults = new Map();
let activeYtsCatalog = null;

function ytsCatalogImdbId(film) {
  const imdbId = String(film.imdbId || "").trim().toLowerCase();
  return /^tt\d+$/.test(imdbId) ? imdbId : "";
}

function ytsCatalogBadgeMarkup(imdbId) {
  return readYtsCatalogResult(imdbId)?.result.status === "found"
    ? `<span class="status-pill is-yts" title="Listed on YTS">YTS</span>`
    : "";
}

function ytsCatalogCardMarkup(film) {
  const imdbId = ytsCatalogImdbId(film);
  return imdbId ? `<span data-yts-imdb="${imdbId}">${ytsCatalogBadgeMarkup(imdbId)}</span>` : "";
}

function readYtsCatalogResult(imdbId) {
  if (!imdbId) return null;
  if (ytsCatalogResults.has(imdbId)) return ytsCatalogResults.get(imdbId);
  try {
    const result = JSON.parse(window.localStorage.getItem(`${ytsCatalogConfig.storagePrefix}${imdbId}`));
    if (!["found", "not_found"].includes(result?.status) || typeof result.checkedAt !== "string" || !Number.isFinite(Date.parse(result.checkedAt))) return null;
    const cached = { result, saved: true };
    ytsCatalogResults.set(imdbId, cached);
    return cached;
  } catch {
    return null;
  }
}

function saveYtsCatalogResult(imdbId, result) {
  const cached = { result, saved: false };
  try {
    window.localStorage.setItem(`${ytsCatalogConfig.storagePrefix}${imdbId}`, JSON.stringify(result));
    cached.saved = true;
  } catch {
    // Keep the result usable for this visit if browser storage is unavailable.
  }
  ytsCatalogResults.set(imdbId, cached);
  document.querySelectorAll(`[data-yts-imdb="${imdbId}"]`).forEach((slot) => {
    slot.innerHTML = ytsCatalogBadgeMarkup(imdbId);
  });
  return cached;
}

async function fetchYtsCatalogResult(imdbId, signal) {
  const url = new URL("list_movies.json", ytsCatalogConfig.apiBase);
  url.searchParams.set("query_term", imdbId);
  url.searchParams.set("limit", "50");
  const response = await fetch(url, { signal, cache: "no-store", credentials: "omit", referrerPolicy: "no-referrer" });
  if (!response.ok) throw new Error(`YTS request failed: ${response.status}`);
  const payload = await response.json();
  const count = payload?.data?.movie_count;
  const movies = payload?.data?.movies ?? [];
  if (payload?.status !== "ok" || !Number.isInteger(count) || count < 0 || !Array.isArray(movies) ||
      (count === 0 && movies.length > 0) || (count > 0 && movies.length === 0)) {
    throw new Error("Unexpected YTS response");
  }
  const found = movies.some((movie) => movie?.imdb_code === imdbId);
  // A nonempty search without an exact match cannot reliably establish absence.
  if (count > 0 && !found) throw new Error("YTS returned no exact IMDb match");
  return { status: found ? "found" : "not_found", checkedAt: new Date().toISOString() };
}

function renderYtsCatalog() {
  const lookup = activeYtsCatalog;
  const card = els.detailContent.querySelector("[data-yts-catalog]");
  if (!lookup || !card) return;
  const { imdbId, result, saved, busy, error } = lookup;
  const status = card.querySelector("[data-yts-status]");
  const meta = card.querySelector("[data-yts-meta]");
  const notice = card.querySelector("[data-yts-notice]");
  const button = card.querySelector("[data-yts-check]");
  status.textContent = result
    ? (result.status === "found" ? "Listed on YTS" : "Not found on YTS")
    : !imdbId ? "IMDb ID required to check" : busy ? "Checking…" : error ? "Could not check YTS" : "Not checked";
  if (result) {
    const checkedAt = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(result.checkedAt));
    const stale = Date.now() - Date.parse(result.checkedAt) >= ytsCatalogConfig.refreshAfterMs;
    meta.textContent = [`Checked ${checkedAt}`, saved ? "Saved in this browser" : "Kept for this visit", stale ? "Refresh recommended" : ""].filter(Boolean).join(" · ");
  } else {
    meta.textContent = imdbId ? "Check this film's listing. Results are saved in this browser." : "This film has no IMDb ID yet.";
  }
  notice.textContent = [
    error ? (result ? "Check failed. Your previous result is unchanged." : "Try again in a moment.") : "",
    result && !saved ? "Could not save in this browser." : "",
  ].filter(Boolean).join(" ");
  notice.hidden = !notice.textContent;
  card.setAttribute("aria-busy", String(busy));
  button.hidden = !imdbId;
  button.disabled = busy;
  button.textContent = busy ? "Checking…" : error ? "Retry" : result ? "Recheck" : "Check YTS";
}

function cancelYtsCatalogCheck() {
  activeYtsCatalog?.controller?.abort();
  activeYtsCatalog = null;
}

async function checkYtsCatalog() {
  const lookup = activeYtsCatalog;
  if (!lookup?.imdbId || lookup.busy) return;
  const controller = new AbortController();
  lookup.controller = controller;
  lookup.busy = true;
  lookup.error = false;
  renderYtsCatalog();
  const timeout = setTimeout(() => controller.abort(), ytsCatalogConfig.timeoutMs);
  try {
    const result = await fetchYtsCatalogResult(lookup.imdbId, controller.signal);
    if (activeYtsCatalog !== lookup || controller.signal.aborted) return;
    Object.assign(lookup, saveYtsCatalogResult(lookup.imdbId, result));
  } catch {
    if (activeYtsCatalog === lookup) lookup.error = true;
  } finally {
    clearTimeout(timeout);
    if (activeYtsCatalog === lookup) {
      lookup.busy = false;
      lookup.controller = null;
      renderYtsCatalog();
    }
  }
}

function openDetail(film) {
  cancelYtsCatalogCheck();
  const events = Array.isArray(film.availability) ? film.availability : [];
  const firstEvent = events[0] || null;
  const selections = filmSelections(film);
  const sourceLinks = selections
    .filter((selection) => selection.sourceUrl)
    .map((selection, index) => `<a href="${escapeHtml(selection.sourceUrl)}" target="_blank" rel="noreferrer">Source ${index + 1}</a>`);
  const links = [
    film.tmdbUrl ? `<a href="${escapeHtml(film.tmdbUrl)}" target="_blank" rel="noreferrer">TMDb</a>` : "",
    film.imdbUrl ? `<a href="${escapeHtml(film.imdbUrl)}" target="_blank" rel="noreferrer">IMDb</a>` : "",
    ...sourceLinks,
  ].filter(Boolean);

  els.detailContent.innerHTML = `
    <div class="detail-toolbar">
      <span>${escapeHtml(selectionSummaryLabel(film))}</span>
      <button class="close-button" type="button" aria-label="Close detail"></button>
    </div>
    <div class="detail-hero">
      <div class="poster">${posterMarkup(film)}</div>
      <div class="detail-copy">
        <h2>${escapeHtml(film.title || "Untitled")}</h2>
        <p>${escapeHtml([film.director, film.premiereYear ? `Premiere ${film.premiereYear}` : "", `${selections.length} selection${selections.length === 1 ? "" : "s"}`].filter(Boolean).join(" - "))}</p>
        <div class="film-facts">
          <span>${escapeHtml(statusLabel(film.trackingStatus))}</span>
          <span>${escapeHtml(primaryRatingLabel(film))}</span>
        </div>
        <div class="link-row">${links.join("")}</div>
      </div>
    </div>
    <div class="detail-body">
      <h3>Festival selections</h3>
      <div class="selection-list">
        ${selections
          .map(
            (selection) => `
              <div class="selection-row">
                <strong>${escapeHtml(shortFestivalLabel(selection.festival) || "Festival")}</strong>
                <span>${escapeHtml([selection.festivalYear, selection.section].filter(Boolean).join(" - ") || "Official selection")}</span>
              </div>
            `
          )
          .join("")}
      </div>
      <h3>Years</h3>
      <div class="metadata-row">
        <span>Festival years <strong>${escapeHtml([...new Set(selections.map((selection) => selection.festivalYear).filter(Boolean))].join(", ") || "Unknown")}</strong></span>
        <span>Premiere year <strong>${escapeHtml(film.premiereYear || "Unknown")}</strong></span>
        <span>Release year <strong>${escapeHtml(film.releaseYear || "Unknown")}</strong></span>
      </div>
      <h3>Availability</h3>
      ${
        firstEvent
          ? `<div class="availability-card availability-summary">
              <strong>Available to watch</strong>
              <p>${escapeHtml(availabilitySummary(firstEvent))}</p>
            </div>`
          : `<div class="availability-card">
              <strong>Not available yet</strong>
              <p>No legal online availability event recorded yet.</p>
            </div>`
      }
      <h3 id="ytsCatalogHeading">YTS catalog</h3>
      <div class="catalog-check" data-yts-catalog role="region" aria-labelledby="ytsCatalogHeading" aria-busy="false">
        <div class="catalog-check-copy" aria-live="polite" aria-atomic="true">
          <strong class="catalog-status" data-yts-status>Not checked</strong>
          <p class="catalog-meta" data-yts-meta></p>
          <p class="catalog-notice" data-yts-notice hidden></p>
        </div>
        <button class="catalog-check-button" type="button" data-yts-check>Check YTS</button>
      </div>
      <h3>Overview</h3>
      <p>${escapeHtml(film.overview || "No overview yet.")}</p>
    </div>
  `;
  els.detailPanel.classList.add("open");
  els.detailPanel.setAttribute("aria-hidden", "false");
  els.overlay.classList.remove("hidden");
  els.detailContent.querySelector(".close-button")?.addEventListener("click", closeDetail);
  const validImdbId = ytsCatalogImdbId(film);
  activeYtsCatalog = { imdbId: validImdbId, result: null, saved: false, busy: false, error: false, ...readYtsCatalogResult(validImdbId) };
  renderYtsCatalog();
  els.detailContent.querySelector("[data-yts-check]")?.addEventListener("click", checkYtsCatalog);
}

function closeDetail() {
  cancelYtsCatalogCheck();
  els.detailPanel.classList.remove("open");
  els.detailPanel.setAttribute("aria-hidden", "true");
  els.overlay.classList.add("hidden");
}

document.querySelectorAll(".tab").forEach((tab) => {
  tab.addEventListener("click", () => {
    state.view = tab.dataset.view;
    render();
  });
});

els.searchInput.addEventListener("input", (event) => {
  state.search = event.target.value;
  render();
});
els.festivalFilter.addEventListener("change", (event) => {
  state.festival = event.target.value;
  render();
});
els.yearFilter.addEventListener("change", (event) => {
  state.year = event.target.value;
  render();
});
els.statusFilter.addEventListener("change", (event) => {
  state.status = event.target.value;
  render();
});
els.sortSelect.addEventListener("change", (event) => {
  state.sort = event.target.value;
  render();
});
els.closeDetail.addEventListener("click", closeDetail);
els.overlay.addEventListener("click", closeDetail);
window.addEventListener("resize", handleResize);

loadData().catch((error) => {
  els.generatedAt.textContent = "Could not load data. Run scripts/Export-TrackerData.ps1 first.";
  els.filmGrid.innerHTML = `<div class="empty">${escapeHtml(error.message)}</div>`;
});
