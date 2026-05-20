const state = {
  data: null,
  view: "available",
  search: "",
  festival: "",
  year: "",
  status: "",
  sort: "rating",
};

const validViews = new Set(["available", "all", "review", "events"]);
const validStatuses = new Set(["", "pending", "available_found", "needs_review"]);
const validSorts = new Set(["rating", "available", "festival", "title"]);
let isCompactLayout = window.matchMedia("(max-width: 680px)").matches;

const els = {
  generatedAt: document.querySelector("#generatedAt"),
  metricFilms: document.querySelector("#metricFilms"),
  metricAvailable: document.querySelector("#metricAvailable"),
  metricReview: document.querySelector("#metricReview"),
  metricEvents: document.querySelector("#metricEvents"),
  searchInput: document.querySelector("#searchInput"),
  festivalFilter: document.querySelector("#festivalFilter"),
  yearFilter: document.querySelector("#yearFilter"),
  statusFilter: document.querySelector("#statusFilter"),
  sortSelect: document.querySelector("#sortSelect"),
  viewKicker: document.querySelector("#viewKicker"),
  viewTitle: document.querySelector("#viewTitle"),
  viewMeta: document.querySelector("#viewMeta"),
  spotlight: document.querySelector("#spotlight"),
  filmGrid: document.querySelector("#filmGrid"),
  reviewTable: document.querySelector("#reviewTable"),
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

const percentLabel = (value) => {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? `${Math.round(number * 100)}%` : "-";
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
  review: {
    kicker: "Review",
    title: "Needs manual check",
    meta: "items to inspect",
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

const selectionLabel = (selection) =>
  [selection.festival, selection.festivalYear, selection.section].filter(Boolean).join(" - ");

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
  const response = await fetch("./data/tracker-data.json", { cache: "no-store" });
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
  els.metricReview.textContent = totals.needsReview ?? 0;
  els.metricEvents.textContent = totals.events ?? 0;
  els.generatedAt.textContent = formatDateTime(state.data.generatedAt);

  const festivals = Array.isArray(state.data.festivals) ? state.data.festivals : [];
  const years = Array.isArray(state.data.years)
    ? state.data.years
    : [...new Set((state.data.films || []).map((film) => film.year).filter(Boolean))].sort((a, b) => Number(b) - Number(a));
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
  if (state.view === "review") {
    films = films.filter((film) => film.needsReview);
  }
  if (state.festival) {
    films = films.filter((film) => filmSelections(film).some((selection) => selection.festival === state.festival));
  }
  if (state.year) {
    films = films.filter((film) => filmSelections(film).some((selection) => String(selection.festivalYear || "") === state.year));
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
    return Number(b.tmdbRating || 0) - Number(a.tmdbRating || 0);
  });

  return films;
}

function renderSpotlight(films) {
  if (state.view !== "available" || films.length === 0) {
    els.spotlight.classList.add("hidden");
    els.spotlight.innerHTML = "";
    return;
  }

  const film = films[0];
  const event = Array.isArray(film.availability) ? film.availability[0] : null;
  els.spotlight.classList.remove("hidden");
  els.spotlight.innerHTML = `
    <article class="spotlight-card">
      <div class="poster">${posterMarkup(film)}</div>
      <div class="spotlight-copy">
        <span class="eyebrow">Latest legal availability</span>
        <h2>${escapeHtml(film.title || "Untitled")}</h2>
        <p>${escapeHtml(film.overview || `${film.director || "Unknown director"} - ${film.festival || "Festival"}`)}</p>
        <div class="film-facts">
          <span>${escapeHtml(film.festival || "Festival")}</span>
          <span>${escapeHtml(ratingLabel(film.tmdbRating))}</span>
          ${event ? `<span>${escapeHtml((event.availability_types || []).join(", "))}</span>` : ""}
        </div>
        <div class="spotlight-actions">
          <button class="primary-action" data-film-id="${escapeHtml(film.id)}">View Details</button>
          ${film.tmdbUrl ? `<a class="secondary-action" href="${escapeHtml(film.tmdbUrl)}" target="_blank" rel="noreferrer">TMDb</a>` : ""}
        </div>
      </div>
    </article>
  `;
  const button = els.spotlight.querySelector("[data-film-id]");
  button?.addEventListener("click", () => openDetail(film));
}

function renderViewHeader(count) {
  const copy = viewCopy[state.view] || viewCopy.available;
  els.viewKicker.textContent = copy.kicker;
  els.viewTitle.textContent = copy.title;
  els.viewMeta.textContent = `${count} ${copy.meta}`;
}

function setMode(mode) {
  els.filmGrid.classList.toggle("hidden", mode !== "grid");
  els.reviewTable.classList.toggle("hidden", mode !== "review");
  els.eventList.classList.toggle("hidden", mode !== "events");
}

function renderFilmGrid() {
  const films = filteredFilms();
  setMode("grid");
  renderViewHeader(films.length);
  renderSpotlight(films);

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
          </div>
          <div class="film-meta">
            <h2 class="film-title">${escapeHtml(film.title || "Untitled")}</h2>
            <p class="film-subtitle">${escapeHtml(film.director || "Unknown director")}</p>
            <p class="film-section">${escapeHtml(film.selectionSummary || film.section || "Official selection")}</p>
            <div class="film-facts">
              <span>${escapeHtml(film.selectionLabels?.length > 1 ? `${film.selectionLabels.length} selections` : film.selectionLabels?.[0] || "Selection")}</span>
              <span>${escapeHtml(ratingLabel(film.tmdbRating))}</span>
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

function renderReviewTable() {
  const films = filteredFilms();
  setMode("review");
  renderViewHeader(films.length);
  renderSpotlight([]);

  if (films.length === 0) {
    els.reviewTable.innerHTML = `<div class="empty">No review items match this view.</div>`;
    return;
  }

  els.reviewTable.innerHTML = `
    <div class="review-row header">
      <span>Film</span><span>Director</span><span>Match</span><span>TMDb</span><span>IMDb</span>
    </div>
    ${films
      .map(
        (film) => `
          <div class="review-row">
            <button data-film-id="${escapeHtml(film.id)}">${escapeHtml(film.title || "Untitled")}<br><small>${escapeHtml(film.selectionSummary || film.festival || "")}</small></button>
            <span>${escapeHtml(film.director || "-")}</span>
            <span>${escapeHtml(percentLabel(film.matchConfidence))}</span>
            <span>${escapeHtml(film.tmdbId || "-")}</span>
            <span>${escapeHtml(film.imdbId || "-")}</span>
          </div>
        `
      )
      .join("")}
  `;

  els.reviewTable.querySelectorAll("button[data-film-id]").forEach((button) => {
    button.addEventListener("click", () => {
      const film = state.data.films.find((item) => item.id === button.dataset.filmId);
      if (film) openDetail(film);
    });
  });
}

function renderEvents() {
  const events = Array.isArray(state.data.events) ? [...state.data.events] : [];
  events.sort((a, b) => String(b.event_date || "").localeCompare(String(a.event_date || "")));
  setMode("events");
  renderViewHeader(events.length);
  renderSpotlight([]);

  if (events.length === 0) {
    els.eventList.innerHTML = `<div class="empty">No availability events yet.</div>`;
    return;
  }

  els.eventList.innerHTML = events
    .map(
      (event) => `
        <article class="event-row">
          <time>${escapeHtml(event.event_date || "No date")}</time>
          <div>
            <h3>${escapeHtml(event.film_title || "Untitled")}</h3>
            <p>${escapeHtml([event.providers?.join(", "), event.countries?.join(", ")].filter(Boolean).join(" - "))}</p>
          </div>
          <span class="chip">${escapeHtml((event.availability_types || []).join(", "))}</span>
        </article>
      `
    )
    .join("");
}

function render() {
  writeUrlState();
  document.querySelectorAll(".tab").forEach((tab) => {
    tab.classList.toggle("active", tab.dataset.view === state.view);
  });
  if (state.view === "events") renderEvents();
  else if (state.view === "review") renderReviewTable();
  else renderFilmGrid();
}

function openDetail(film) {
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
    <div class="detail-hero">
      <div class="poster">${posterMarkup(film)}</div>
      <div class="detail-body">
        <h2>${escapeHtml(film.title || "Untitled")}</h2>
        <p>${escapeHtml([film.director, film.filmYear ? `Film ${film.filmYear}` : "", `${selections.length} selection${selections.length === 1 ? "" : "s"}`].filter(Boolean).join(" - "))}</p>
        <div class="film-facts">
          <span>${escapeHtml(statusLabel(film.trackingStatus))}</span>
          <span>${escapeHtml(ratingLabel(film.tmdbRating))}</span>
          ${film.needsReview ? `<span>Needs review</span>` : ""}
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
                <strong>${escapeHtml(selection.festival || "Festival")}</strong>
                <span>${escapeHtml([selection.festivalYear, selection.section].filter(Boolean).join(" - ") || "Official selection")}</span>
              </div>
            `
          )
          .join("")}
      </div>
      <h3>Years</h3>
      <p>${escapeHtml([
        `Festival years: ${[...new Set(selections.map((selection) => selection.festivalYear).filter(Boolean))].join(", ") || "Unknown"}`,
        `Film year: ${film.filmYear || "Unknown"}`
      ].join(" - "))}</p>
      <h3>Availability</h3>
      ${
        firstEvent
          ? `<div class="availability-card availability-summary">
              <strong>Available to watch</strong>
              <p>${escapeHtml(availabilitySummary(firstEvent))}</p>
            </div>`
          : `<p>No legal online availability event recorded yet.</p>`
      }
      <h3>Overview</h3>
      <p>${escapeHtml(film.overview || "No overview yet.")}</p>
    </div>
  `;
  els.detailPanel.classList.add("open");
  els.detailPanel.setAttribute("aria-hidden", "false");
  els.overlay.classList.remove("hidden");
}

function closeDetail() {
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
