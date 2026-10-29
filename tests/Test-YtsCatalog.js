// Run with: node --test tests/Test-YtsCatalog.js
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

const source = fs.readFileSync(path.join(__dirname, "../web/app.js"), "utf8");
const prefix = "festival-tracker:yts:v1:";
const film = { id: "film-a", title: "Film A", imdbId: "tt0111161" };
const otherFilm = { id: "film-b", title: "Film B", imdbId: "tt0068646" };
const found = (imdbId = film.imdbId, torrents = []) => ({ status: "ok", data: { movie_count: 1, movies: [{ imdb_code: imdbId, torrents }] } });
const response = (payload, status = 200, headers = {}) => ({ ok: status === 200, status, headers: { get: (name) => headers[name] ?? null }, json: async () => payload });
const priorResult = () => ({ status: "found", checkedAt: new Date().toISOString(), torrents: [] });

function createApp({ store = new Map(), storageBlocked = false, handler = async () => response(found()), config = {} } = {}) {
  const elements = new Map();
  const cardSlots = new Map();
  function element(selector) {
    if (!elements.has(selector)) {
      elements.set(selector, {
        textContent: "", innerHTML: "", hidden: false, disabled: false,
        style: {},
        classList: { add() {}, remove() {}, toggle() {} },
        attributes: {},
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
  const context = vm.createContext({
    URL, URLSearchParams, AbortController, Intl, Date, setTimeout, clearTimeout,
    document: { querySelector: element, querySelectorAll: (selector) => cardSlots.get(selector) || [], scripts: [] },
    window: {
      location: { search: "", pathname: "/", href: "http://localhost/" },
      history: { replaceState() {} }, matchMedia: () => ({ matches: false }), addEventListener() {},
      localStorage: {
        getItem(key) { if (storageBlocked) throw new Error("Storage blocked"); return store.get(key) ?? null; },
        setItem(key, value) { if (storageBlocked) throw new Error("Storage blocked"); store.set(key, value); },
      },
    },
    fetch: async (url, options) => {
      if (String(url).startsWith("./data/")) return response({ films: [], events: [] });
      requests.push({ url: new URL(url), options });
      return handler(url, options);
    },
  });
  vm.runInContext(source, context);
  context.testConfig = { minIntervalMs: 0, retryDelayMs: 1, hideProgressAfterMs: 10, ...config };
  vm.runInContext("Object.assign(ytsCatalogConfig, testConfig)", context);
  const api = vm.runInContext("({ openDetail, closeDetail, checkYtsCatalog, startYtsBatch, stopYtsBatch, preferredYtsTorrent })", context);
  return {
    ...api, store, requests, context,
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
    mountCardSlots(imdbId, count = 1) {
      const slots = Array.from({ length: count }, () => ({ innerHTML: "" }));
      cardSlots.set(`[data-yts-imdb="${imdbId}"]`, slots);
      return slots;
    },
    status: () => element("[data-yts-status]").textContent,
    meta: () => element("[data-yts-meta]").textContent,
    notice: () => element("[data-yts-notice]").textContent,
    button: () => element("[data-yts-check]"),
    download: () => element("[data-yts-download]"),
    subtitles: () => element("[data-yts-subtitles]"),
    actions: () => element("[data-yts-actions]"),
    torrentSpec: () => element("[data-yts-spec]"),
    detailMarkup: () => element("#detailContent").innerHTML,
    batchButton: () => element("#ytsBatchCheck"),
    batchCount: () => element("#ytsBatchCount").textContent,
    batchStatus: () => element("#ytsBatchStatus"),
    batchText: () => element("#ytsBatchText").textContent,
    batchFill: () => element("#ytsBatchFill").style.width,
  };
}

test("manual lookup saves an exact IMDb match and restores it after a reload without another request", async () => {
  const app = createApp();
  app.openDetail(film);
  assert.equal(app.status(), "Not checked");
  assert.equal(app.requests.length, 0);
  await app.checkYtsCatalog();
  assert.equal(app.status(), "Listed on YTS");
  assert.equal(app.requests[0].url.searchParams.get("query_term"), film.imdbId);
  const saved = JSON.parse(app.store.get(prefix + film.imdbId));
  assert.equal(saved.status, "found");
  assert.ok(Number.isFinite(Date.parse(saved.checkedAt)));
  const reloaded = createApp({ store: app.store });
  reloaded.openDetail(film);
  assert.equal(reloaded.status(), "Listed on YTS");
  assert.match(reloaded.meta(), /^Checked /);
  assert.doesNotMatch(reloaded.meta(), /Saved in this browser|Refresh recommended/);
  assert.equal(reloaded.requests.length, 0);
});

test("a successful empty response is saved as not found", async () => {
  const app = createApp({ handler: async () => response({ status: "ok", data: { movie_count: 0 } }) });
  app.openDetail(film);
  await app.checkYtsCatalog();
  assert.equal(app.status(), "Not found on YTS");
  assert.equal(JSON.parse(app.store.get(prefix + film.imdbId)).status, "not_found");
});

test("HTTP, network, API and ambiguous responses preserve the previous successful record", async (t) => {
  const failures = {
    http: async () => response(null, 503),
    network: async () => { throw new Error("Offline"); },
    api: async () => response({ status: "error" }),
    malformed: async () => response({ status: "ok", data: { movie_count: 1 } }),
    inconsistent: async () => response({ status: "ok", data: { movie_count: 0, movies: [{ imdb_code: film.imdbId }] } }),
    unrelated: async () => response(found(otherFilm.imdbId)),
  };
  for (const [name, handler] of Object.entries(failures)) {
    await t.test(name, async () => {
      const previous = JSON.stringify(priorResult());
      const store = new Map([[prefix + film.imdbId, previous]]);
      const app = createApp({ store, handler });
      app.openDetail(film);
      await app.checkYtsCatalog();
      assert.equal(app.status(), "Listed on YTS");
      assert.equal(store.get(prefix + film.imdbId), previous);
      assert.match(app.notice(), /Check failed/);
      assert.equal(app.button().textContent, "Retry");
    });
  }
});

test("switching films or closing the panel aborts and discards late responses", async (t) => {
  for (const action of ["switch", "close"]) {
    await t.test(action, async () => {
      let finish;
      const app = createApp({ handler: () => new Promise((resolve) => { finish = resolve; }) });
      app.openDetail(film);
      const pending = app.checkYtsCatalog();
      if (action === "switch") app.openDetail(otherFilm);
      else app.closeDetail();
      assert.equal(app.requests[0].options.signal.aborted, true);
      finish(response(found()));
      await pending;
      assert.equal(app.store.size, 0);
      if (action === "close") app.openDetail(otherFilm);
      assert.equal(app.status(), "Not checked");
    });
  }
});

test("repeated clicks share one pending lookup and keep the previous result visible", async () => {
  let finish;
  const store = new Map([[prefix + film.imdbId, JSON.stringify(priorResult())]]);
  const app = createApp({ store, handler: () => new Promise((resolve) => { finish = resolve; }) });
  app.openDetail(film);
  const pending = app.checkYtsCatalog();
  await app.checkYtsCatalog();
  assert.equal(app.requests.length, 1);
  assert.equal(app.button().disabled, true);
  assert.equal(app.status(), "Listed on YTS");
  finish(response(found()));
  await pending;
  assert.equal(app.button().disabled, false);
  assert.equal(app.button().textContent, "Recheck");
});

test("stale results remain visible while their version information refreshes and corrupt browser records do not break details", () => {
  const stale = createApp({ store: new Map([[prefix + film.imdbId, JSON.stringify({ ...priorResult(), checkedAt: new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString() })]]) });
  stale.openDetail(film);
  assert.equal(stale.status(), "Listed on YTS");
  assert.match(stale.meta(), /^Checked /);
  assert.equal(stale.requests.length, 1);
  for (const corrupt of ["{", JSON.stringify({ status: "found", checkedAt: "invalid" }), JSON.stringify({ status: "error", checkedAt: new Date().toISOString() })]) {
    const app = createApp({ store: new Map([[prefix + film.imdbId, corrupt]]) });
    app.openDetail(film);
    assert.equal(app.status(), "Not checked");
  }
});

test("blocked storage keeps results for this visit with an honest save notice", async () => {
  const app = createApp({ storageBlocked: true });
  app.openDetail(film);
  await app.checkYtsCatalog();
  assert.equal(app.status(), "Listed on YTS");
  assert.match(app.notice(), /Could not save/);
  assert.doesNotMatch(app.meta(), /Saved in this browser/);
  app.closeDetail();
  app.openDetail(film);
  assert.equal(app.status(), "Listed on YTS");
  assert.equal(app.requests.length, 1);
});

test("a timeout preserves the saved result and re-enables retry", async () => {
  const previous = JSON.stringify(priorResult());
  const app = createApp({
    store: new Map([[prefix + film.imdbId, previous]]),
    handler: (_url, { signal }) => new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(new Error("Aborted")), { once: true })),
  });
  vm.runInContext("ytsCatalogConfig.timeoutMs = 5", app.context);
  app.openDetail(film);
  await app.checkYtsCatalog();
  assert.equal(app.status(), "Listed on YTS");
  assert.equal(app.store.get(prefix + film.imdbId), previous);
  assert.match(app.notice(), /Check failed/);
  assert.equal(app.button().disabled, false);
});

test("missing or invalid IMDb IDs do not send requests", async () => {
  const app = createApp();
  for (const imdbId of [undefined, "", "not-an-id"]) {
    app.openDetail({ ...film, imdbId });
    await app.checkYtsCatalog();
    assert.equal(app.status(), "IMDb ID required to check");
    assert.equal(app.button().hidden, true);
    assert.equal(app.subtitles().hidden, true);
    assert.equal(app.subtitles().getAttribute("href"), null);
  }
  assert.equal(app.requests.length, 0);
});

test("only confirmed listings expose an IMDb-based SubHD search, even without a download, without querying subtitles", async () => {
  const app = createApp();
  app.openDetail(film);
  assert.equal(app.subtitles().hidden, true);
  assert.equal(app.actions().hidden, true);
  assert.equal(app.requests.length, 0);
  await app.checkYtsCatalog();
  assert.equal(app.download().hidden, true);
  assert.equal(app.subtitles().hidden, false);
  assert.equal(app.actions().hidden, false);
  assert.equal(app.subtitles().getAttribute("href"), `https://subhd.me/search/${film.imdbId}`);
  assert.match(app.subtitles().getAttribute("aria-label"), new RegExp(`${film.imdbId}.*new tab`));
  assert.equal(app.requests.length, 1);
  assert.equal(app.requests[0].url.hostname, "movies-api.accel.li");
  app.openDetail(otherFilm);
  assert.equal(app.subtitles().hidden, true);
  assert.equal(app.subtitles().getAttribute("href"), null);
  assert.equal(app.actions().hidden, true);
});

test("a failed recheck preserves SubHD search and the compact date for the previous confirmed listing", async () => {
  const previous = priorResult();
  const app = createApp({
    store: new Map([[prefix + film.imdbId, JSON.stringify(previous)]]),
    handler: async () => { throw new Error("Offline"); },
  });
  app.openDetail(film);
  const date = app.meta();
  await app.checkYtsCatalog();
  assert.equal(app.subtitles().hidden, false);
  assert.equal(app.subtitles().getAttribute("href"), `https://subhd.me/search/${film.imdbId}`);
  assert.equal(app.meta(), date);
  assert.match(app.notice(), /Check failed/);
});

test("film grids restore only confirmed YTS badges from the existing browser cache without a request", () => {
  const store = new Map([
    [prefix + film.imdbId, JSON.stringify(priorResult())],
    [prefix + otherFilm.imdbId, JSON.stringify({ status: "not_found", checkedAt: new Date().toISOString() })],
  ]);
  const app = createApp({ store });
  const markup = app.gridMarkup([
    { ...film, imdbId: ` ${film.imdbId.toUpperCase()} ` }, otherFilm,
    { id: "unchecked", title: "Unchecked", imdbId: "tt1234567" },
    { id: "invalid", title: "Invalid", imdbId: "not-an-id" },
    { id: "missing", title: "No IMDb ID" },
  ]);
  assert.equal((markup.match(/title="Listed on YTS"/g) || []).length, 1);
  assert.match(markup, /data-yts-imdb="tt0111161"><span[^>]*>YTS<\/span>/);
  assert.doesNotMatch(markup, /✓|Not found on YTS|Not checked/);
  assert.equal(app.requests.length, 0);
  const reloaded = createApp({ store });
  assert.match(reloaded.gridMarkup([film]), />YTS<\/span>/);
  assert.equal(reloaded.requests.length, 0);
});

test("a successful lookup immediately updates every matching card without touching another film", async () => {
  const app = createApp();
  const slots = app.mountCardSlots(film.imdbId, 2);
  const [otherSlot] = app.mountCardSlots(otherFilm.imdbId);
  app.openDetail(film);
  await app.checkYtsCatalog();
  for (const slot of slots) assert.match(slot.innerHTML, />YTS<\/span>/);
  assert.equal(otherSlot.innerHTML, "");
});

test("an unsuccessful request preserves a card badge, while a confirmed empty result removes it", async () => {
  let empty = false;
  const app = createApp({
    store: new Map([[prefix + film.imdbId, JSON.stringify(priorResult())]]),
    handler: async () => {
      if (empty) return response({ status: "ok", data: { movie_count: 0 } });
      throw new Error("Offline");
    },
  });
  const slots = app.mountCardSlots(film.imdbId, 2);
  for (const slot of slots) slot.innerHTML = "existing badge";
  app.openDetail(film);
  await app.checkYtsCatalog();
  for (const slot of slots) assert.equal(slot.innerHTML, "existing badge");
  empty = true;
  await app.checkYtsCatalog();
  for (const slot of slots) assert.equal(slot.innerHTML, "");
  assert.doesNotMatch(app.gridMarkup([film]), /Listed on YTS/);
});

test("corrupt or blocked storage leaves cards usable and a new result remains visible for this visit", async () => {
  const corrupt = createApp({ store: new Map([[prefix + film.imdbId, "{"]]) });
  assert.doesNotMatch(corrupt.gridMarkup([film]), /Listed on YTS/);
  const blocked = createApp({ storageBlocked: true });
  assert.doesNotMatch(blocked.gridMarkup([film]), /Listed on YTS/);
  const [slot] = blocked.mountCardSlots(film.imdbId);
  blocked.openDetail(film);
  await blocked.checkYtsCatalog();
  assert.match(slot.innerHTML, />YTS<\/span>/);
  assert.match(blocked.gridMarkup([film]), />YTS<\/span>/);
  assert.equal(blocked.requests.length, 1);
});

const batchFilm = (number, overrides = {}) => ({ id: `batch-${number}`, title: `Match ${number}`, imdbId: `tt${1000000 + number}`, ...overrides });
const nextTurn = () => new Promise((resolve) => setImmediate(resolve));
async function until(predicate) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
  assert.fail("Expected asynchronous condition did not become true");
}

test("batch candidates use the current filters, normalize and deduplicate IDs, and skip confirmed listings and missing IDs", async () => {
  const listed = batchFilm(1);
  const retry = batchFilm(2);
  const unchecked = batchFilm(3);
  const outside = batchFilm(4, { title: "Outside" });
  const saved = JSON.stringify(priorResult());
  const app = createApp({
    store: new Map([
      [prefix + listed.imdbId, saved],
      [prefix + retry.imdbId, JSON.stringify({ status: "not_found", checkedAt: new Date().toISOString() })],
    ]),
    handler: async (url) => response(found(new URL(url).searchParams.get("query_term"))),
  });
  await app.ready();
  app.gridMarkup([listed, retry, unchecked, { ...retry, id: "duplicate", imdbId: ` ${retry.imdbId.toUpperCase()} ` }, outside, batchFilm(5, { imdbId: "" })]);
  app.setFilters({ search: "Match" });
  assert.equal(app.batchCount(), "2");
  await app.startYtsBatch();
  assert.deepEqual(app.requests.map(({ url }) => url.searchParams.get("query_term")).sort(), [retry.imdbId, unchecked.imdbId].sort());
  assert.equal(app.store.get(prefix + listed.imdbId), saved);
  assert.equal(app.batchCount(), "0");
  assert.equal(app.batchButton().disabled, true);
});

test("a batch keeps its starting selection after filters change and continues when details close", async () => {
  const films = [batchFilm(1), batchFilm(2), batchFilm(3)];
  const outside = batchFilm(4, { title: "Outside" });
  const finishes = new Map();
  const app = createApp({ handler: (url) => new Promise((resolve) => finishes.set(new URL(url).searchParams.get("query_term"), resolve)) });
  await app.ready();
  app.gridMarkup([...films, outside]);
  app.setFilters({ search: "Match" });
  const pending = app.startYtsBatch();
  assert.equal(app.requests.length, 2);
  app.openDetail(films[0]);
  assert.equal(app.button().disabled, true);
  await app.checkYtsCatalog();
  assert.equal(app.requests.length, 2);
  app.closeDetail();
  assert.ok(app.requests.every(({ options }) => !options.signal.aborted));
  app.setFilters({ search: "Outside" });
  finishes.get(films[0].imdbId)(response(found(films[0].imdbId)));
  await until(() => finishes.has(films[2].imdbId));
  for (const film of films.slice(1)) finishes.get(film.imdbId)(response(found(film.imdbId)));
  await pending;
  assert.equal(app.requests.length, 3);
  assert.equal(app.store.has(prefix + outside.imdbId), false);
  assert.equal(app.batchCount(), "1");
  assert.match(app.batchText(), /3\/3/);
});

test("batch and single-film checks share a global limit of two active requests", async () => {
  const films = [batchFilm(1), batchFilm(2), batchFilm(3), batchFilm(4)];
  const outside = batchFilm(5, { title: "Outside" });
  let active = 0;
  let maximum = 0;
  const finishes = [];
  const app = createApp({ handler: (url) => {
    active++;
    maximum = Math.max(maximum, active);
    return new Promise((resolve) => finishes.push(() => {
      active--;
      resolve(response(found(new URL(url).searchParams.get("query_term"))));
    }));
  } });
  await app.ready();
  app.gridMarkup([...films, outside]);
  app.setFilters({ search: "Match" });
  const batch = app.startYtsBatch();
  app.openDetail(outside);
  const single = app.checkYtsCatalog();
  assert.equal(app.requests.length, 2);
  let completed = 0;
  while (completed < 5) {
    await until(() => finishes.length > 0);
    finishes.shift()();
    completed++;
    await nextTurn();
  }
  await Promise.all([batch, single]);
  assert.equal(maximum, 2);
  assert.equal(app.requests.length, 5);
  assert.equal(app.status(), "Listed on YTS");
});

test("stopping aborts active requests and drops queued work while keeping completed results", async () => {
  const films = [batchFilm(1), batchFilm(2), batchFilm(3), batchFilm(4)];
  const app = createApp({ handler: (url, { signal }) => {
    const imdbId = new URL(url).searchParams.get("query_term");
    if (imdbId === films[0].imdbId) return response(found(imdbId));
    return new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(new Error("Aborted")), { once: true }));
  } });
  await app.ready();
  app.gridMarkup(films);
  const pending = app.startYtsBatch();
  await until(() => app.store.has(prefix + films[0].imdbId));
  app.stopYtsBatch();
  const requestCount = app.requests.length;
  await pending;
  await nextTurn();
  assert.equal(app.requests.length, requestCount);
  assert.ok(requestCount < films.length);
  assert.equal(app.store.size, 1);
  assert.equal(app.batchCount(), "3");
  assert.equal(app.batchStatus().hidden, true);
  assert.equal(app.batchText(), "");
});

test("completion removes all progress text and occupied space after the brief completion delay", async () => {
  const films = [batchFilm(1), batchFilm(2)];
  const app = createApp({ handler: async (url) => response(found(new URL(url).searchParams.get("query_term"))) });
  await app.ready();
  app.gridMarkup(films);
  await app.startYtsBatch();
  assert.equal(app.batchStatus().hidden, false);
  assert.equal(app.batchText(), "YTS · 2/2");
  assert.equal(app.batchCount(), "0");
  await until(() => app.batchStatus().hidden);
  assert.equal(app.batchText(), "");
  assert.equal(app.batchFill(), "0%");
});

test("rate-limited checks honor Retry-After and request pacing before a bounded retry", async () => {
  const starts = [];
  const app = createApp({
    config: { minIntervalMs: 15 },
    handler: async (url) => {
      starts.push(Date.now());
      return starts.length === 1 ? response(null, 429, { "Retry-After": "0.03" }) : response(found(new URL(url).searchParams.get("query_term")));
    },
  });
  await app.ready();
  app.gridMarkup([batchFilm(1)]);
  await app.startYtsBatch();
  assert.equal(starts.length, 2);
  assert.ok(starts[1] - starts[0] >= 30);
  assert.equal(app.batchCount(), "0");
});

test("repeated service failures are bounded and never become a not-found result", async () => {
  const film = batchFilm(1);
  const previous = JSON.stringify({ status: "not_found", checkedAt: new Date(0).toISOString() });
  const app = createApp({ store: new Map([[prefix + film.imdbId, previous]]), handler: async () => response(null, 503) });
  await app.ready();
  app.gridMarkup([film]);
  await app.startYtsBatch();
  assert.equal(app.requests.length, 2);
  assert.equal(app.store.get(prefix + film.imdbId), previous);
  assert.equal(app.batchCount(), "1");
});

test("Finds has no idle bulk action but a running batch remains stoppable there", async () => {
  const app = createApp({ handler: (_url, { signal }) => new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(new Error("Aborted")), { once: true })) });
  await app.ready();
  app.gridMarkup([batchFilm(1)]);
  app.setFilters({ view: "events" });
  assert.equal(app.batchButton().hidden, true);
  app.setFilters({ view: "all" });
  const pending = app.startYtsBatch();
  app.setFilters({ view: "events" });
  assert.equal(app.batchButton().hidden, false);
  app.stopYtsBatch();
  await pending;
  assert.equal(app.batchButton().hidden, true);
});

const torrent = (number, overrides = {}) => ({
  url: `https://yts.gg/torrent/download/${number.toString(16).padStart(40, "0")}`,
  quality: "2160p", video_codec: "x265", type: "web", bit_depth: "10", audio_channels: "5.1", size_bytes: 4 * 1024 ** 3,
  ...overrides,
});

test("lookup persists version data and exposes the highest resolution with x265 ahead of source preference", async () => {
  const versions = [
    torrent(1, { video_codec: "x264", type: "bluray", size_bytes: 8 * 1024 ** 3 }),
    torrent(2),
    torrent(3, { quality: "1080p", type: "bluray" }),
  ];
  const app = createApp({ handler: async () => response(found(film.imdbId, versions)) });
  app.openDetail(film);
  assert.equal(app.download().hidden, true);
  await app.checkYtsCatalog();
  assert.equal(app.download().hidden, false);
  assert.equal(app.download().getAttribute("href"), versions[1].url);
  assert.equal(app.download().textContent, "Download Torrent · 2160p");
  assert.match(app.torrentSpec().innerHTML, /WEB/);
  assert.match(app.torrentSpec().innerHTML, /x265/);
  assert.equal(JSON.parse(app.store.get(prefix + film.imdbId)).torrents.length, 3);
  const reloaded = createApp({ store: app.store });
  reloaded.openDetail(film);
  assert.equal(reloaded.download().getAttribute("href"), versions[1].url);
  assert.equal(reloaded.requests.length, 0);
});

test("codec aliases, resolution precedence, and x264 fallback follow the agreed selection rules", () => {
  const app = createApp();
  for (const codec of ["H.265", "HEVC", "h-265", "X265"]) {
    const versions = [torrent(1, { quality: "1080p", video_codec: "x264", type: "bluray" }), torrent(2, { quality: "1080p", video_codec: codec })];
    const best = app.preferredYtsTorrent({ status: "found", torrents: versions });
    assert.equal(best.url, versions[1].url);
    assert.equal(best.video_codec, "x265");
  }
  const highResolution = torrent(1, { video_codec: "x264" });
  assert.equal(app.preferredYtsTorrent({ status: "found", torrents: [torrent(2, { quality: "1080p" }), highResolution] }).url, highResolution.url);
  const fallback = torrent(3, { quality: "1080p", video_codec: "x264", type: "bluray" });
  assert.equal(app.preferredYtsTorrent({ status: "found", torrents: [torrent(1, { quality: "720p", video_codec: "x264" }), torrent(2, { quality: "1080p", video_codec: "x264" }), fallback] }).url, fallback.url);
});

test("same-resolution and same-codec ties use source, bit depth, channels, then size", () => {
  const app = createApp();
  const choices = [
    [torrent(1, { type: "web", bit_depth: "12" }), torrent(2, { type: "bluray", bit_depth: "8" })],
    [torrent(1, { bit_depth: "8" }), torrent(2, { bit_depth: "10" })],
    [torrent(1, { audio_channels: "2.0" }), torrent(2, { audio_channels: "5.1" })],
    [torrent(1, { size_bytes: 1024 ** 3 }), torrent(2, { size_bytes: 2 * 1024 ** 3 })],
  ];
  for (const versions of choices) {
    assert.equal(app.preferredYtsTorrent({ status: "found", torrents: versions }).url, versions[1].url);
    assert.equal(app.preferredYtsTorrent({ status: "found", torrents: [...versions].reverse() }).url, versions[1].url);
  }
});

test("invalid links and unsupported resource shapes cannot create a download action", async () => {
  const invalid = [null, "not a resource", torrent(1, { url: "javascript:alert(1)" }), torrent(1, { url: "http://yts.gg/torrent/download/" + "a".repeat(40) }), torrent(1, { url: "https://yts.gg.example.com/torrent/download/" + "a".repeat(40) }), torrent(1, { url: "https://user:secret@yts.gg/torrent/download/" + "a".repeat(40) }), torrent(1, { url: "https://yts.gg/movies/example" }), torrent(1, { quality: "3D" }), torrent(1, { quality: "unknown" })];
  const app = createApp({ handler: async () => response(found(film.imdbId, invalid)) });
  app.openDetail(film);
  await app.checkYtsCatalog();
  assert.equal(app.status(), "Listed on YTS");
  assert.equal(app.download().hidden, true);
  assert.equal(app.download().getAttribute("href"), null);
  assert.match(app.notice(), /No usable Torrent link/);
  app.closeDetail();
  app.openDetail(film);
  assert.equal(app.requests.length, 1);
});

test("legacy found-only caches upgrade on demand once while retaining the original card badge", async () => {
  const previous = { status: "found", checkedAt: new Date().toISOString() };
  let finish;
  const app = createApp({ store: new Map([[prefix + film.imdbId, JSON.stringify(previous)]]), handler: () => new Promise(resolve => { finish = resolve; }) });
  await app.ready();
  app.gridMarkup([film]);
  assert.equal(app.batchCount(), "0");
  assert.equal(app.requests.length, 0);
  app.openDetail(film);
  assert.equal(app.status(), "Listed on YTS");
  assert.equal(app.button().disabled, true);
  assert.equal(app.download().hidden, true);
  finish(response(found(film.imdbId, [torrent(1)])));
  await until(() => !app.button().disabled);
  assert.equal(app.download().getAttribute("href"), torrent(1).url);
  app.closeDetail();
  app.openDetail(film);
  assert.equal(app.requests.length, 1);
});

test("expired version data refreshes on opening details without losing an existing download on failure", async () => {
  const previous = JSON.stringify({ ...priorResult(), checkedAt: new Date(0).toISOString(), torrents: [torrent(1, { quality: "1080p" })] });
  const app = createApp({ store: new Map([[prefix + film.imdbId, previous]]), handler: async () => { throw new Error("Offline"); } });
  app.openDetail(film);
  assert.equal(app.download().getAttribute("href"), torrent(1).url);
  await until(() => app.button().textContent === "Retry");
  assert.equal(app.download().getAttribute("href"), torrent(1).url);
  assert.equal(app.store.get(prefix + film.imdbId), previous);
  assert.match(app.notice(), /Check failed/);
});

test("a confirmed not-found response removes a previously valid download and its specification", async () => {
  const app = createApp({ store: new Map([[prefix + film.imdbId, JSON.stringify({ ...priorResult(), torrents: [torrent(1)] })]]), handler: async () => response({ status: "ok", data: { movie_count: 0 } }) });
  app.openDetail(film);
  assert.equal(app.download().hidden, false);
  await app.checkYtsCatalog();
  assert.equal(app.status(), "Not found on YTS");
  assert.equal(app.download().hidden, true);
  assert.equal(app.download().getAttribute("href"), null);
  assert.equal(app.torrentSpec().hidden, true);
  assert.equal(app.subtitles().hidden, true);
  assert.equal(app.subtitles().getAttribute("href"), null);
  assert.equal(app.actions().hidden, true);
});

test("batch checks retain download metadata for later details without rechecking or initiating downloads", async () => {
  const movie = batchFilm(1);
  const app = createApp({ handler: async url => response(found(new URL(url).searchParams.get("query_term"), [torrent(1)])) });
  await app.ready();
  app.gridMarkup([movie]);
  await app.startYtsBatch();
  assert.equal(app.requests.length, 1);
  assert.equal(JSON.parse(app.store.get(prefix + movie.imdbId)).torrents[0].url, torrent(1).url);
  app.openDetail(movie);
  assert.equal(app.download().getAttribute("href"), torrent(1).url);
  assert.equal(app.requests.length, 1);
});

test("details keep distinct year meanings, put overview before tools, and attach sources to their selections", () => {
  const app = createApp();
  app.openDetail({
    ...film, premiereYear: 2025, releaseYear: 2026, director: "A Director", overview: "Story summary", tmdbUrl: "https://www.themoviedb.org/movie/1", imdbUrl: "https://www.imdb.com/title/tt0111161/",
    selections: [{ festival: "Cannes", festivalYear: 2025, section: "Competition", sourceUrl: "https://example.org/cannes" }, { festival: "Venice", festivalYear: 2026, section: "Main", sourceUrl: "https://example.org/venice" }],
  });
  const markup = app.detailMarkup();
  assert.match(markup, /Premiere 2025 · Release 2026/);
  assert.doesNotMatch(markup, /<h3>Years<\/h3>|Source 1|Source 2/);
  assert.ok(markup.indexOf("<h3>Overview") < markup.indexOf("<h3>Availability"));
  assert.ok(markup.indexOf("<h3>Availability") < markup.indexOf('id="ytsCatalogHeading"'));
  assert.match(markup, /href="https:\/\/example.org\/cannes"[^>]*aria-label="Source for Cannes - 2025 - Competition"/);
  assert.match(markup, /href="https:\/\/example.org\/venice"[^>]*aria-label="Source for Venice - 2026 - Main"/);
});
