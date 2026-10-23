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
const response = (payload, status = 200) => ({ ok: status === 200, status, json: async () => payload });
const priorResult = () => ({ status: "found", checkedAt: new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString() });

function createApp({ store = new Map(), storageBlocked = false, handler = async () => response(found()) } = {}) {
  const elements = new Map();
  function element(selector) {
    if (!elements.has(selector)) {
      elements.set(selector, {
        textContent: "", innerHTML: "", hidden: false, disabled: false,
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
    document: { querySelector: element, querySelectorAll: () => [], scripts: [] },
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
  const api = vm.runInContext("({ openDetail, closeDetail, checkYtsCatalog })", context);
  return {
    ...api, store, requests, context,
    status: () => element("[data-yts-status]").textContent,
    meta: () => element("[data-yts-meta]").textContent,
    notice: () => element("[data-yts-notice]").textContent,
    button: () => element("[data-yts-check]"),
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
