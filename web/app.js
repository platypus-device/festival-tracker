const state = {
  data: null,
  view: "available",
  search: "",
  festival: "",
  status: "",
  sort: "rating",
};

const els = {
  generatedAt: document.querySelector("#generatedAt"),
  metricFilms: document.querySelector("#metricFilms"),
  metricAvailable: document.querySelector("#metricAvailable"),
  metricReview: document.querySelector("#metricReview"),
  metricEvents: document.querySelector("#metricEvents"),
  searchInput: document.querySelector("#searchInput"),
  festivalFilter: document.querySelector("#festivalFilter"),
  statusFilter: document.querySelector("#statusFilter"),
  sortSelect: document.querySelector("#sortSelect"),
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
  return `Updated ${date.toLocaleString()}`;
};

const statusLabel = (status) => {
  if (status === "available_found") return "Available";
  if (status === "needs_review") return "Needs review";
  return "Pending";
};

const ratingLabel = (rating) => {
  const value = Number(rating);
  return Number.isFinite(value) && value > 0 ? value.toFixed(1) : "Unrated";
};

const percentLabel = (value) => {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? `${Math.round(number * 100)}%` : "-";
};

const posterMarkup = (film) => {
  const title = escapeHtml(film.title || "Untitled");
  if (film.posterUrl) {
    return `<img src="${escapeHtml(film.posterUrl)}" alt="${title} poster" loading="lazy" />`;
  }
  return `<div class="poster-fallback">${title}</div>`;
};

async function loadData() {
  const response = await fetch("./data/tracker-data.json", { cache: "no-store" });
  if (!response.ok) throw new Error(`Data request failed: ${response.status}`);
  state.data = await response.json();
  setupFilters();
  render();
}

function setupFilters() {
  const totals = state.data.totals || {};
  els.metricFilms.textContent = totals.films ?? 0;
  els.metricAvailable.textContent = totals.available ?? 0;
  els.metricReview.textContent = totals.needsReview ?? 0;
  els.metricEvents.textContent = totals.events ?? 0;
  els.generatedAt.textContent = formatDateTime(state.data.generatedAt);

  const festivals = Array.isArray(state.data.festivals) ? state.data.festivals : [];
  els.festivalFilter.innerHTML = [
    `<option value="">All festivals</option>`,
    ...festivals.map((festival) => `<option value="${escapeHtml(festival)}">${escapeHtml(festival)}</option>`),
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
    films = films.filter((film) => film.festival === state.festival);
  }
  if (state.status) {
    films = films.filter((film) => film.trackingStatus === state.status);
  }
  if (query) {
    films = films.filter((film) => {
      const haystack = [film.title, film.originalTitle, film.director, film.festival, film.section]
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

function setMode(mode) {
  els.filmGrid.classList.toggle("hidden", mode !== "grid");
  els.reviewTable.classList.toggle("hidden", mode !== "review");
  els.eventList.classList.toggle("hidden", mode !== "events");
}

function renderFilmGrid() {
  const films = filteredFilms();
  setMode("grid");
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
            <span class="status-pill">${escapeHtml(statusLabel(film.trackingStatus))}</span>
          </div>
          <div class="film-meta">
            <h2 class="film-title">${escapeHtml(film.title || "Untitled")}</h2>
            <p class="film-subtitle">${escapeHtml(film.director || "Unknown director")}</p>
            <div class="film-facts">
              <span>${escapeHtml(film.festival || "Festival")}</span>
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
            <button data-film-id="${escapeHtml(film.id)}">${escapeHtml(film.title || "Untitled")}<br><small>${escapeHtml(film.festival || "")}</small></button>
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
  document.querySelectorAll(".tab").forEach((tab) => {
    tab.classList.toggle("active", tab.dataset.view === state.view);
  });
  if (state.view === "events") renderEvents();
  else if (state.view === "review") renderReviewTable();
  else renderFilmGrid();
}

function openDetail(film) {
  const events = Array.isArray(film.availability) ? film.availability : [];
  const links = [
    film.tmdbUrl ? `<a href="${escapeHtml(film.tmdbUrl)}" target="_blank" rel="noreferrer">TMDb</a>` : "",
    film.imdbUrl ? `<a href="${escapeHtml(film.imdbUrl)}" target="_blank" rel="noreferrer">IMDb</a>` : "",
    film.sourceUrl ? `<a href="${escapeHtml(film.sourceUrl)}" target="_blank" rel="noreferrer">Lineup source</a>` : "",
  ].filter(Boolean);

  els.detailContent.innerHTML = `
    <div class="detail-hero">
      <div class="poster">${posterMarkup(film)}</div>
      <div class="detail-body">
        <h2>${escapeHtml(film.title || "Untitled")}</h2>
        <p>${escapeHtml([film.director, film.year, film.festival].filter(Boolean).join(" - "))}</p>
        <div class="film-facts">
          <span>${escapeHtml(statusLabel(film.trackingStatus))}</span>
          <span>${escapeHtml(ratingLabel(film.tmdbRating))}</span>
          ${film.needsReview ? `<span>Needs review</span>` : ""}
        </div>
        <div class="link-row">${links.join("")}</div>
      </div>
    </div>
    <div class="detail-body">
      <h3>Section</h3>
      <p>${escapeHtml(film.section || "No section")}</p>
      <h3>Availability</h3>
      ${
        events.length
          ? `<div class="availability-list">${events
              .map(
                (event) => `
                  <div class="availability-card">
                    <div class="film-facts">
                      <span>${escapeHtml(event.event_date || "No date")}</span>
                      ${(event.availability_types || []).map((type) => `<span>${escapeHtml(type)}</span>`).join("")}
                    </div>
                    <p>${escapeHtml((event.providers || []).join(", ") || "Provider not listed")}</p>
                    <p>${escapeHtml((event.countries || []).join(", ") || "Countries not listed")}</p>
                    <div class="link-row">
                      ${(event.source_urls || [])
                        .map((url, index) => `<a href="${escapeHtml(url)}" target="_blank" rel="noreferrer">Source ${index + 1}</a>`)
                        .join("")}
                    </div>
                  </div>
                `
              )
              .join("")}</div>`
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

loadData().catch((error) => {
  els.generatedAt.textContent = "Could not load data. Run scripts/Export-TrackerData.ps1 first.";
  els.filmGrid.innerHTML = `<div class="empty">${escapeHtml(error.message)}</div>`;
});
