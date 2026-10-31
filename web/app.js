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
const validStatuses = new Set(["", "pending", "available_found"]);
const validSorts = new Set(["rating", "available", "festival", "title"]);
let isCompactLayout = window.matchMedia("(max-width: 680px)").matches;

const els = {
  generatedAt: document.querySelector("#generatedAt"),
  metricFilms: document.querySelector("#metricFilms"),
  metricAvailable: document.querySelector("#metricAvailable"),
  searchInput: document.querySelector("#searchInput"),
  festivalFilter: document.querySelector("#festivalFilter"),
  yearFilter: document.querySelector("#yearFilter"),
  statusFilter: document.querySelector("#statusFilter"),
  statusFilterField: document.querySelector("#statusFilterField"),
  browseControls: document.querySelector("#browseControls"),
  filterFields: document.querySelector("#filterFields"),
  filterToggle: document.querySelector("#filterToggle"),
  resultsToolbar: document.querySelector("#resultsToolbar"),
  resultsCount: document.querySelector("#resultsCount"),
  sortSelect: document.querySelector("#sortSelect"),
  sortControl: document.querySelector(".sort-control"),
  viewTitle: document.querySelector("#viewTitle"),
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
  const day = new Intl.DateTimeFormat("en-GB", { dateStyle: "medium" }).format(date);
  const time = new Intl.DateTimeFormat("en-GB", { timeStyle: "short", hour12: false }).format(date);
  return `Updated ${day} · ${time}`;
};

const statusLabel = (status) => {
  if (status === "available_found") return "Available";
  return "Pending";
};

const statusClass = (status) => {
  if (status === "available_found") return "is-available";
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
  available: "Available films",
  all: "All films",
  events: "Discovery log",
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
  if (state.view === "all" && state.status) params.set("status", state.status);
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
  drawer.classList.toggle("open", !isCompactLayout);
  els.filterToggle.setAttribute("aria-expanded", String(!isCompactLayout));
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
  if (state.view === "all" && state.status) {
    films = films.filter((film) => state.status === "available_found"
      ? film.trackingStatus === "available_found"
      : film.trackingStatus !== "available_found");
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
  els.viewTitle.textContent = viewCopy[state.view] || viewCopy.available;
  els.viewTitle.classList.toggle("sr-only", state.view !== "events");
  els.resultsCount.textContent = `${count} ${count === 1 ? "film" : "films"}`;
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
              <span class="film-selection">${escapeHtml(selectionSummaryLabel(film))}</span>
              <span class="film-rating">${escapeHtml(primaryRatingLabel(film))}</span>
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
  els.statusFilterField.hidden = state.view !== "all";
  els.filterFields.classList.toggle("has-status", state.view === "all");
  els.browseControls.hidden = state.view === "events";
  els.resultsToolbar.hidden = state.view === "events";
  els.resultsCount.hidden = state.view === "events";
  els.sortControl.hidden = state.view === "events";
  document.querySelectorAll(".tab").forEach((tab) => {
    tab.classList.toggle("active", tab.dataset.view === state.view);
    tab.setAttribute("aria-pressed", String(tab.dataset.view === state.view));
  });
  if (state.view === "events") renderEvents();
  else renderFilmGrid();
}

function ytsCatalogImdbId(film) {
  const imdbId = String(film.imdbId || "").trim().toLowerCase();
  return /^tt\d+$/.test(imdbId) ? imdbId : "";
}

function safeExternalUrl(value) {
  try {
    const url = new URL(String(value || ""));
    return ["https:", "http:"].includes(url.protocol) && !url.username && !url.password ? url.href : "";
  } catch {
    return "";
  }
}

function normalizeYtsTorrent(torrent) {
  if (!torrent || typeof torrent !== "object") return null;
  const href = safeExternalUrl(torrent.url);
  if (!href) return null;
  const url = new URL(href);
  if (url.protocol !== "https:" || url.port || !["yts.gg", "yts.bz", "yts.mx"].includes(url.hostname) || !/^\/torrent\/download\/[a-f0-9]{40}$/i.test(url.pathname)) return null;
  const resolution = Number(/^(\d{3,4})p(?:\b|$)/i.exec(String(torrent.quality || ""))?.[1]);
  if (!resolution) return null;
  const codec = String(torrent.video_codec || "").trim().toLowerCase().replace(/[.\s-]/g, "");
  const source = String(torrent.type || "").trim().toLowerCase().replace(/[\s-]/g, "");
  const depth = Number(torrent.bit_depth);
  const audio = String(torrent.audio_channels || "").trim();
  const bytes = Number(torrent.size_bytes);
  const sizeBytes = Number.isSafeInteger(bytes) && bytes > 0 ? bytes : 0;
  const size = String(torrent.size || "").trim();
  return {
    url: href,
    quality: `${resolution}p`,
    video_codec: ["x265", "h265", "hevc"].includes(codec) ? "x265" : ["x264", "h264", "avc"].includes(codec) ? "x264" : "",
    type: source === "bluray" ? "BluRay" : ["web", "webrip", "webdl"].includes(source) ? "WEB" : "",
    bit_depth: Number.isInteger(depth) && depth > 0 && depth <= 32 ? depth : 0,
    audio_channels: /^\d{1,2}(?:\.\d{1,2}){0,2}$/.test(audio) ? audio : "",
    size_bytes: sizeBytes,
    size: sizeBytes ? `${(sizeBytes / (sizeBytes >= 1024 ** 3 ? 1024 ** 3 : 1024 ** 2)).toFixed(2)} ${sizeBytes >= 1024 ** 3 ? "GB" : "MB"}` : /^\d+(?:\.\d+)?\s*(?:KB|MB|GB|TB)$/i.test(size) ? size : "",
  };
}

function preferredYtsTorrent(result) {
  if (result?.status !== "found" || !Array.isArray(result.torrents)) return null;
  const codecRank = (torrent) => torrent.video_codec === "x265" ? 2 : torrent.video_codec === "x264" ? 1 : 0;
  const sourceRank = (torrent) => torrent.type === "BluRay" ? 2 : torrent.type === "WEB" ? 1 : 0;
  const audioRank = (torrent) => torrent.audio_channels.split(".").reduce((sum, channels) => sum + Number(channels), 0);
  return result.torrents.map(normalizeYtsTorrent).filter(Boolean).sort((a, b) =>
    Number.parseInt(b.quality, 10) - Number.parseInt(a.quality, 10) ||
    codecRank(b) - codecRank(a) || sourceRank(b) - sourceRank(a) ||
    b.bit_depth - a.bit_depth || audioRank(b) - audioRank(a) || b.size_bytes - a.size_bytes || a.url.localeCompare(b.url)
  )[0] || null;
}

function ytsTorrentSpec(torrent) {
  return [torrent.quality, torrent.type, torrent.video_codec, torrent.bit_depth ? `${torrent.bit_depth}bit` : "", torrent.audio_channels ? `${torrent.audio_channels} ch` : "", torrent.size].filter(Boolean);
}

function readYtsCatalogResult(film) {
  const imdbId = ytsCatalogImdbId(film);
  const result = film.ytsCatalog;
  if (film.trackingStatus !== "available_found" || !imdbId || result?.imdbId !== imdbId ||
      !["found", "not_found"].includes(result.status) || typeof result.checkedAt !== "string" ||
      !Number.isFinite(Date.parse(result.checkedAt))) return null;
  return result;
}

function ytsCatalogCardMarkup(film) {
  return readYtsCatalogResult(film)?.status === "found"
    ? `<span class="status-pill is-yts" title="Listed on YTS">YTS</span>`
    : "";
}

function renderYtsCatalog(film) {
  const card = els.detailContent.querySelector("[data-yts-catalog]");
  if (!card) return;
  const imdbId = ytsCatalogImdbId(film);
  const result = readYtsCatalogResult(film);
  const status = card.querySelector("[data-yts-status]");
  const meta = card.querySelector("[data-yts-meta]");
  const notice = card.querySelector("[data-yts-notice]");
  const spec = card.querySelector("[data-yts-spec]");
  const actions = card.querySelector("[data-yts-actions]");
  const download = card.querySelector("[data-yts-download]");
  const subtitles = card.querySelector("[data-yts-subtitles]");
  const torrent = preferredYtsTorrent(result);
  const canSearchSubtitles = result?.status === "found";
  spec.hidden = !torrent;
  spec.innerHTML = torrent ? ytsTorrentSpec(torrent).map((text) => `<span>${escapeHtml(text)}</span>`).join(" · ") : "";
  download.hidden = !torrent;
  if (torrent) {
    download.setAttribute("href", torrent.url);
    download.textContent = `Download Torrent · ${torrent.quality}`;
  } else {
    download.removeAttribute("href");
    download.textContent = "";
  }
  subtitles.hidden = !canSearchSubtitles;
  if (canSearchSubtitles) {
    subtitles.setAttribute("href", `https://subhd.me/search/${encodeURIComponent(imdbId)}`);
    subtitles.setAttribute("aria-label", `Search SubHD subtitles using IMDb ${imdbId} (opens in a new tab)`);
  } else {
    subtitles.removeAttribute("href");
    subtitles.removeAttribute("aria-label");
  }
  actions.hidden = !torrent && !canSearchSubtitles;
  status.textContent = result
    ? (result.status === "found" ? "Listed on YTS" : "Not found on YTS")
    : !imdbId ? "IMDb ID unavailable" : "Not checked yet";
  meta.textContent = result
    ? `Checked ${new Intl.DateTimeFormat(undefined, { dateStyle: "medium" }).format(new Date(result.checkedAt))}`
    : film.trackingStatus !== "available_found" ? "Checks start once available to watch." : imdbId ? "Awaiting scheduled check." : "";
  meta.hidden = !meta.textContent;
  notice.textContent = result?.status === "found" && !torrent ? "No usable Torrent link in this result." : "";
  notice.hidden = !notice.textContent;
}

let detailReturnFocus = null;

function openDetail(film) {
  if (els.detailPanel.getAttribute("aria-hidden") !== "false") detailReturnFocus = document.activeElement;
  const events = Array.isArray(film.availability) ? film.availability : [];
  const firstEvent = events[0] || null;
  const selections = filmSelections(film);
  const links = [
    safeExternalUrl(film.tmdbUrl) ? `<a href="${escapeHtml(safeExternalUrl(film.tmdbUrl))}" target="_blank" rel="noopener noreferrer">TMDb <span aria-hidden="true">↗</span></a>` : "",
    safeExternalUrl(film.imdbUrl) ? `<a href="${escapeHtml(safeExternalUrl(film.imdbUrl))}" target="_blank" rel="noopener noreferrer">IMDb <span aria-hidden="true">↗</span></a>` : "",
  ].filter(Boolean);

  els.detailContent.innerHTML = `
    <div class="detail-toolbar">
      <span>${escapeHtml(selectionSummaryLabel(film))}</span>
      <button class="close-button" type="button" aria-label="Close detail"></button>
    </div>
    <div class="detail-inner">
      <div class="detail-hero">
      <div class="poster">${posterMarkup(film)}</div>
      <div class="detail-copy">
        <h2 id="detailTitle">${escapeHtml(film.title || "Untitled")}</h2>
        <p class="detail-director">${escapeHtml(film.director || "Unknown director")}</p>
        <p class="detail-years"><span>${escapeHtml(film.premiereYear ? `Premiere ${film.premiereYear}` : "Premiere year unknown")}</span><span>${escapeHtml(film.releaseYear ? `Release ${film.releaseYear}` : "Release year unknown")}</span></p>
      </div>
      </div>
      <div class="detail-support">
        <span class="detail-status ${escapeHtml(statusClass(film.trackingStatus))}">${escapeHtml(statusLabel(film.trackingStatus))}</span>
        <span class="detail-rating">${escapeHtml(primaryRatingLabel(film))}</span>
        <div class="detail-links">${links.join("")}</div>
      </div>
    <div class="detail-body">
      <section class="detail-section">
      <h3>Festival selections</h3>
      <div class="selection-list">
        ${selections
          .map(
            (selection) => `
              <div class="selection-row">
                <strong>${escapeHtml(shortFestivalLabel(selection.festival) || "Festival")}</strong>
                <span class="selection-description">${escapeHtml([selection.festivalYear, selection.section].filter(Boolean).join(" · ") || "Official selection")}</span>
                ${safeExternalUrl(selection.sourceUrl) ? `<a class="selection-source" href="${escapeHtml(safeExternalUrl(selection.sourceUrl))}" target="_blank" rel="noopener noreferrer" aria-label="Source for ${escapeHtml(selectionLabel(selection))}">Source <span aria-hidden="true">↗</span></a>` : ""}
              </div>
            `
          )
          .join("")}
      </div>
      </section>
      <section class="detail-section">
      <h3>Overview</h3>
      <p class="detail-overview">${escapeHtml(film.overview || "No overview yet.")}</p>
      </section>
      <section class="detail-section">
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
      </section>
      <section class="detail-section">
      <h3 id="ytsCatalogHeading">YTS catalog</h3>
      <div class="catalog-check" data-yts-catalog role="region" aria-labelledby="ytsCatalogHeading">
        <div class="catalog-check-copy">
          <div class="catalog-check-header">
            <strong class="catalog-status" data-yts-status aria-live="polite" aria-atomic="true">Not checked</strong>
          </div>
          <p class="catalog-meta" data-yts-meta></p>
        </div>
        <p class="catalog-spec" data-yts-spec hidden></p>
        <div class="catalog-actions" data-yts-actions hidden>
          <a class="catalog-download" data-yts-download target="_blank" rel="noopener noreferrer" referrerpolicy="no-referrer" type="application/x-bittorrent" hidden></a>
          <a class="catalog-subtitles" data-yts-subtitles target="_blank" rel="noopener noreferrer" referrerpolicy="no-referrer" hidden>Search SubHD subtitles <span aria-hidden="true">↗</span></a>
        </div>
        <p class="catalog-notice" data-yts-notice role="status" aria-live="polite" hidden></p>
      </div>
      </section>
    </div>
    </div>
  `;
  els.detailPanel.classList.add("open");
  els.detailPanel.setAttribute("aria-hidden", "false");
  els.detailPanel.inert = false;
  document.querySelector(".shell").inert = true;
  document.body?.classList.add("detail-open");
  els.detailPanel.scrollTop = 0;
  els.overlay.classList.remove("hidden");
  els.detailContent.querySelector(".close-button")?.addEventListener("click", closeDetail);
  els.detailContent.querySelector(".close-button")?.focus?.({ preventScroll: true });
  renderYtsCatalog(film);
}

function closeDetail() {
  els.detailPanel.classList.remove("open");
  els.detailPanel.setAttribute("aria-hidden", "true");
  els.detailPanel.inert = true;
  document.querySelector(".shell").inert = false;
  document.body?.classList.remove("detail-open");
  els.overlay.classList.add("hidden");
  detailReturnFocus?.focus?.({ preventScroll: true });
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
els.filterToggle.addEventListener("click", () => {
  const expanded = els.filterToggle.getAttribute("aria-expanded") !== "true";
  document.querySelector(".filter-drawer").classList.toggle("open", expanded);
  els.filterToggle.setAttribute("aria-expanded", String(expanded));
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
window.addEventListener("keydown", (event) => {
  if (els.detailPanel.getAttribute("aria-hidden") !== "false") return;
  if (event.key === "Escape") closeDetail();
  if (event.key !== "Tab") return;
  const focusable = [...els.detailContent.querySelectorAll("button:not(:disabled), a[href]")];
  const first = focusable[0];
  const last = focusable[focusable.length - 1];
  if (event.shiftKey && document.activeElement === first) {
    event.preventDefault();
    last?.focus();
  } else if (!event.shiftKey && document.activeElement === last) {
    event.preventDefault();
    first?.focus();
  }
});

loadData().catch((error) => {
  els.generatedAt.textContent = "Could not load data. Run scripts/Export-TrackerData.ps1 first.";
  els.filmGrid.innerHTML = `<div class="empty">${escapeHtml(error.message)}</div>`;
});
