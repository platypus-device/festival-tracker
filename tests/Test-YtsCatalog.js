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
const found = (imdbId = film.imdbId) => ({ status: "ok", data: { movie_count: 1, movies: [{ imdb_code: imdbId }] } });
const response = (payload, status = 200, headers = {}) => ({ ok: status === 200, status, headers: { get: (name) => headers[name] ?? null }, json: async () => payload });
const priorResult = () => ({ status: "found", checkedAt: new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString() });

function createApp({ store = new Map(), storageBlocked = false, handler = async () => response(found()), config = {} } = {}) {
  const elements = new Map();
  const cardSlots = new Map();
  function element(selector) {
    if (!elements.has(selector)) {
      elements.set(selector, {
        textContent: "", innerHTML: "", hidden: false, disabled: false,
        style: {},
        classList: { add() {}, remove() {}, toggle() {} },
        addEventListener() {}, setAttribute() {},
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
  const api = vm.runInContext("({ openDetail, closeDetail, checkYtsCatalog, startYtsBatch, stopYtsBatch })", context);
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
  assert.match(reloaded.meta(), /Saved in this browser/);
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

test("stale results remain visible and corrupt browser records do not break details", () => {
  const stale = createApp({ store: new Map([[prefix + film.imdbId, JSON.stringify(priorResult())]]) });
  stale.openDetail(film);
  assert.equal(stale.status(), "Listed on YTS");
  assert.match(stale.meta(), /Refresh recommended/);
  assert.equal(stale.requests.length, 0);
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
  }
  assert.equal(app.requests.length, 0);
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
