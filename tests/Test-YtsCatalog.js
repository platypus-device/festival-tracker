// Run with: node --test tests/Test-YtsCatalog.js
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

const source = fs.readFileSync(path.join(__dirname, "../web/app.js"), "utf8");
const prefix = "festival-tracker:yts:v1:";
const film = { id: "film-a", title: "Film A", imdbId: "tt0111161", trackingStatus: "available_found" };
const otherFilm = { id: "film-b", title: "Film B", imdbId: "tt0068646", trackingStatus: "pending" };
const catalog = (status = "found", torrents = []) => ({ imdbId: film.imdbId, status, checkedAt: "2026-10-31T01:00:00Z", firstFoundAt: status === "found" ? "2026-10-31T01:00:00Z" : "", torrents });
const response = (payload, status = 200, headers = {}) => ({ ok: status === 200, status, headers: { get: (name) => headers[name] ?? null }, json: async () => payload });

const browseData = {
  films: [
    { ...film, trackingStatus: "available_found", lowConfidence: true },
    { ...otherFilm, trackingStatus: "pending" },
    { id: "legacy", title: "Legacy review", trackingStatus: "needs_review" },
  ],
  events: [{ id: "event-a", film_id: film.id, film_title: film.title, event_date: "2026-10-31" }],
};

test("obsolete review URLs do not produce a dead-end filter", async () => {
  const app = createApp({ data: browseData, search: "?view=all&status=needs_review" });
  await app.ready();
  assert.equal(app.filteredFilms().length, 3);
  assert.equal(app.element("#statusFilter").value, "");
  assert.equal(app.urls.at(-1), "/?view=all");
});

test("availability filters stay independent of metadata quality", async () => {
  const app = createApp({ data: browseData, search: "?view=all&status=available_found" });
  await app.ready();
  assert.deepEqual(Array.from(app.filteredFilms(), f => f.id), [film.id]);
  assert.equal(app.element("#statusFilterField").hidden, false);
  app.setFilters({ status: "pending" });
  assert.deepEqual(Array.from(app.filteredFilms(), f => f.id).sort(), [otherFilm.id, "legacy"].sort());
});

test("hidden status filters cannot empty Available and are restored on returning to All films", async () => {
  const app = createApp({ data: browseData, search: "?view=all&status=pending" });
  await app.ready();
  app.setFilters({ view: "available" });
  assert.deepEqual(Array.from(app.filteredFilms(), f => f.id), [film.id]);
  assert.equal(app.element("#statusFilterField").hidden, true);
  assert.equal(app.urls.at(-1), "/");
  app.setFilters({ view: "all" });
  assert.equal(app.filteredFilms().length, 2);
  assert.match(app.urls.at(-1), /status=pending/);
});

test("Available URLs with incompatible status parameters still show available films", async () => {
  const app = createApp({ data: browseData, search: "?status=pending" });
  await app.ready();
  assert.deepEqual(Array.from(app.filteredFilms(), f => f.id), [film.id]);
  assert.equal(app.urls.at(-1), "/");
});

test("Finds hides controls that do not filter events", async () => {
  const app = createApp({ data: browseData, search: "?view=events" });
  await app.ready();
  assert.equal(app.element("#browseControls").hidden, true);
  assert.equal(app.element("#resultsToolbar").hidden, true);
  assert.equal(app.element(".sort-control").hidden, true);
  assert.equal(app.element("#viewTitle").textContent, "Discovery log");
  assert.equal(app.element("#statusFilterField").hidden, true);
  assert.match(app.element("#eventList").innerHTML, /Film A/);
  app.setFilters({ view: "all" });
  assert.equal(app.element("#browseControls").hidden, false);
  assert.equal(app.element("#resultsToolbar").hidden, false);
  assert.equal(app.element(".sort-control").hidden, false);
});

test("details make the background inert only while open", () => {
  const app = createApp();
  app.openDetail(film);
  assert.equal(app.element(".shell").inert, true);
  assert.equal(app.element("#detailPanel").inert, false);
  assert.match(app.detailMarkup(), /id="detailTitle"/);
  app.closeDetail();
  assert.equal(app.element(".shell").inert, false);
  assert.equal(app.element("#detailPanel").inert, true);
});

function createApp({ store = new Map(), storageBlocked = false, search = "", data = { films: [], events: [] } } = {}) {
  const elements = new Map();
  function element(selector) {
    if (!elements.has(selector)) {
      elements.set(selector, {
        textContent: "", innerHTML: "", hidden: false, disabled: false, style: {},
        classList: { add() {}, remove() {}, toggle() {} }, attributes: {},
        addEventListener() {},
        setAttribute(name, value) { this.attributes[name] = value; },
        getAttribute(name) { return this.attributes[name] ?? null; },
        removeAttribute(name) { delete this.attributes[name]; },
        querySelector: element, querySelectorAll: () => [],
      });
    }
    return elements.get(selector);
  }
  const requests = [];
  const urls = [];
  const context = vm.createContext({
    URL, URLSearchParams, Intl, Date,
    document: { querySelector: element, querySelectorAll: () => [], scripts: [] },
    window: {
      location: { search, pathname: "/", href: "http://localhost/" },
      history: { replaceState(_state, _title, url) { urls.push(url); } },
      matchMedia: () => ({ matches: false }), addEventListener() {},
      localStorage: {
        getItem(key) { if (storageBlocked) throw new Error("Storage blocked"); return store.get(key) ?? null; },
        setItem() { throw new Error("The shared catalog must not write browser storage"); },
      },
    },
    fetch: async (url) => {
      if (String(url).startsWith("./data/")) return response(data);
      requests.push(String(url));
      throw new Error("Unexpected browser API request");
    },
  });
  vm.runInContext(source, context);
  const api = vm.runInContext("({ openDetail, closeDetail, preferredYtsTorrent, filteredFilms })", context);
  return {
    ...api, requests, element, urls,
    ready: () => new Promise((resolve) => setImmediate(resolve)),
    setFilters(filters) {
      context.testFilters = filters;
      vm.runInContext("Object.assign(state, testFilters); render();", context);
    },
    gridMarkup(films) {
      context.gridFilms = films;
      vm.runInContext('state.data = { films: gridFilms, events: [] }; state.view = "all"; renderFilmGrid();', context);
      return element("#filmGrid").innerHTML;
    },
    status: () => element("[data-yts-status]").textContent,
    meta: () => element("[data-yts-meta]").textContent,
    notice: () => element("[data-yts-notice]").textContent,
    download: () => element("[data-yts-download]"),
    subtitles: () => element("[data-yts-subtitles]"),
    actions: () => element("[data-yts-actions]"),
    torrentSpec: () => element("[data-yts-spec]"),
    detailMarkup: () => element("#detailContent").innerHTML,
  };
}

const torrent = (number = 1, options = {}) => ({
  url: `https://yts.gg/torrent/download/${number.toString(16).padStart(40, "0")}`,
  quality: "1080p", video_codec: "x265", type: "bluray", bit_depth: "10", audio_channels: "5.1", size_bytes: 2 * 1024 ** 3,
  ...options,
});

test("shared results restore badges and resource links on every device without API calls", async () => {
  const shared = { ...film, ytsCatalog: catalog("found", [torrent()]) };
  for (const storageBlocked of [false, true]) {
    const app = createApp({ storageBlocked, data: { films: [shared], events: [] } });
    await app.ready();
    assert.match(app.gridMarkup([shared]), /title="Listed on YTS">YTS/);
    app.openDetail(shared);
    assert.equal(app.status(), "Listed on YTS");
    assert.match(app.meta(), /Checked/);
    assert.equal(app.download().getAttribute("href"), torrent().url);
    assert.equal(app.subtitles().getAttribute("href"), "https://subhd.me/search/tt0111161");
    assert.equal(app.torrentSpec().hidden, false);
    assert.equal(app.requests.length, 0);
    app.closeDetail();
  }
});

test("old browser-only caches cannot override the published Notion snapshot", async () => {
  const app = createApp({ store: new Map([[prefix + film.imdbId, JSON.stringify(catalog())]]) });
  const shared = { ...film, ytsCatalog: catalog("not_found") };
  assert.doesNotMatch(app.gridMarkup([shared]), /Listed on YTS/);
  app.openDetail(shared);
  assert.equal(app.status(), "Not found on YTS");
  assert.equal(app.download().hidden, true);
  assert.equal(app.subtitles().hidden, true);
  await app.ready();
  assert.equal(app.requests.length, 0);
});

test("pending films do not display catalog annotations or run checks", () => {
  const pending = { ...film, trackingStatus: "pending", ytsCatalog: catalog() };
  const app = createApp();
  assert.doesNotMatch(app.gridMarkup([pending]), /Listed on YTS/);
  app.openDetail(pending);
  assert.equal(app.status(), "Not checked yet");
  assert.match(app.meta(), /once available/);
  assert.equal(app.requests.length, 0);
});

test("unchecked and malformed results remain unchecked without a lookup", () => {
  for (const ytsCatalog of [null, {}, catalog("unknown"), { ...catalog(), checkedAt: "invalid" }, { ...catalog(), imdbId: otherFilm.imdbId }]) {
    const app = createApp();
    app.openDetail({ ...film, ytsCatalog });
    assert.equal(app.status(), "Not checked yet");
    assert.equal(app.meta(), "Awaiting scheduled check.");
    assert.equal(app.download().getAttribute("href"), null);
    assert.equal(app.requests.length, 0);
  }
  const app = createApp();
  app.openDetail({ ...film, imdbId: "invalid" });
  assert.equal(app.status(), "IMDb ID unavailable");
});

test("confirmed results stay visible without browser refreshes regardless of age", async () => {
  const app = createApp();
  app.openDetail({ ...film, ytsCatalog: { ...catalog("found", [torrent()]), checkedAt: "2020-01-01T00:00:00Z" } });
  await app.ready();
  assert.equal(app.status(), "Listed on YTS");
  assert.equal(app.download().getAttribute("href"), torrent().url);
  assert.equal(app.requests.length, 0);
});

test("resource preference preserves resolution, codec, source, and technical tie breaks", () => {
  const app = createApp();
  const high = torrent(3, { quality: "2160p", video_codec: "x264" });
  assert.equal(app.preferredYtsTorrent(catalog("found", [torrent(1), high])).url, high.url);
  for (const versions of [
    [torrent(1, { video_codec: "x264" }), torrent(2)],
    [torrent(1, { type: "web", bit_depth: "12" }), torrent(2, { type: "bluray", bit_depth: "8" })],
    [torrent(1, { bit_depth: "8" }), torrent(2, { bit_depth: "10" })],
    [torrent(1, { audio_channels: "2.0" }), torrent(2, { audio_channels: "5.1" })],
    [torrent(1, { size_bytes: 1024 ** 3 }), torrent(2)],
  ]) {
    assert.equal(app.preferredYtsTorrent(catalog("found", versions)).url, versions[1].url);
    assert.equal(app.preferredYtsTorrent(catalog("found", [...versions].reverse())).url, versions[1].url);
  }
});

test("invalid resource links cannot become download actions", () => {
  const invalid = [null, "invalid", torrent(1, { url: "javascript:alert(1)" }), torrent(1, { url: "http://yts.gg/torrent/download/" + "a".repeat(40) }), torrent(1, { url: "https://yts.gg.example.com/torrent/download/" + "a".repeat(40) }), torrent(1, { url: "https://user:secret@yts.gg/torrent/download/" + "a".repeat(40) }), torrent(1, { quality: "3D" })];
  const app = createApp();
  app.openDetail({ ...film, ytsCatalog: catalog("found", invalid) });
  assert.equal(app.status(), "Listed on YTS");
  assert.equal(app.download().hidden, true);
  assert.equal(app.download().getAttribute("href"), null);
  assert.match(app.notice(), /No usable Torrent link/);
  assert.equal(app.subtitles().hidden, false);
});

test("opening another film clears resource actions from the previous result", () => {
  const app = createApp();
  app.openDetail({ ...film, ytsCatalog: catalog("found", [torrent()]) });
  assert.equal(app.download().hidden, false);
  app.closeDetail();
  app.openDetail({ ...film, ytsCatalog: catalog("not_found") });
  assert.equal(app.download().hidden, true);
  assert.equal(app.download().getAttribute("href"), null);
  assert.equal(app.torrentSpec().hidden, true);
  assert.equal(app.subtitles().getAttribute("href"), null);
  assert.equal(app.actions().hidden, true);
});

test("manual catalog checks and progress UI are absent", () => {
  const html = fs.readFileSync(path.join(__dirname, "../web/index.html"), "utf8");
  assert.doesNotMatch(html, /ytsBatch|Check YTS/);
  assert.doesNotMatch(source, /movies-api|localStorage|startYtsBatch|checkYtsCatalog/);
  const app = createApp();
  app.openDetail(film);
  assert.doesNotMatch(app.detailMarkup(), /data-yts-check|Recheck|Check YTS/);
});

test("details keep distinct year meanings, put overview before tools, and attach sources to their selections", () => {
  const app = createApp();
  app.openDetail({
    ...film, premiereYear: 2025, releaseYear: 2026, director: "A Director", overview: "Story summary", tmdbUrl: "https://www.themoviedb.org/movie/1", imdbUrl: "https://www.imdb.com/title/tt0111161/",
    selections: [{ festival: "Cannes", festivalYear: 2025, section: "Competition", sourceUrl: "https://example.org/cannes" }, { festival: "Venice", festivalYear: 2026, section: "Main", sourceUrl: "https://example.org/venice" }],
  });
  const markup = app.detailMarkup();
  assert.match(markup, /Premiere 2025/);
  assert.match(markup, /Release 2026/);
  assert.doesNotMatch(markup, /<h3>Years<\/h3>|Source 1|Source 2/);
  assert.ok(markup.indexOf("<h3>Overview") < markup.indexOf("<h3>Availability"));
  assert.ok(markup.indexOf("<h3>Availability") < markup.indexOf('id="ytsCatalogHeading"'));
  assert.match(markup, /href="https:\/\/example.org\/cannes"[^>]*aria-label="Source for Cannes - 2025 - Competition"/);
  assert.match(markup, /href="https:\/\/example.org\/venice"[^>]*aria-label="Source for Venice - 2026 - Main"/);
});
