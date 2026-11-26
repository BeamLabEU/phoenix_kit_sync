// The delegated `data-pks-copy` listener of priv/static/assets/phoenix_kit_sync.js,
// run against a fake page. `node --test test/js` (the Elixir suite runs it too, from
// test/phoenix_kit_sync/web/copy_code_js_test.exs, when node is installed).
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const SOURCE = fs.readFileSync(
  path.join(__dirname, "../../priv/static/assets/phoenix_kit_sync.js"),
  "utf8"
);

function icon(hidden) {
  const classes = new Set(hidden ? ["hidden"] : []);
  return {
    classList: {
      toggle(name, on) { if (on) classes.add(name); else classes.delete(name); },
      contains(name) { return classes.has(name); }
    }
  };
}

function page(clipboard) {
  const listeners = [];
  const timers = [];
  const window = {};
  const sandbox = {
    window,
    document: { addEventListener(type, fn) { listeners.push({ type, fn }); } },
    navigator: { clipboard },
    setTimeout(fn, ms) { timers.push({ fn, ms }); }
  };
  vm.createContext(sandbox);
  const load = () => vm.runInContext(SOURCE, sandbox);
  load();
  return { window, listeners, timers, load };
}

function button(code) {
  const copy = icon(false);
  const check = icon(true);
  const el = {
    copy,
    check,
    getAttribute(name) { return name === "data-pks-copy" ? code : null; },
    querySelector(selector) { return selector === ".copy-icon" ? copy : selector === ".check-icon" ? check : null; },
    closest(selector) { return selector === "[data-pks-copy]" ? el : null; }
  };
  return el;
}

test("a click on a data-pks-copy button copies its text and shows the check for two seconds", async () => {
  const written = [];
  const env = page({ writeText(text) { written.push(text); return Promise.resolve(); } });
  const el = button("ABCD1234");
  const inner = { closest: (selector) => el.closest(selector) };

  assert.deepStrictEqual(env.listeners.map((l) => l.type), ["click"]);
  env.listeners[0].fn({ target: inner });
  await new Promise((resolve) => setImmediate(resolve));

  assert.deepStrictEqual(written, ["ABCD1234"]);
  assert.strictEqual(el.copy.classList.contains("hidden"), true);
  assert.strictEqual(el.check.classList.contains("hidden"), false);

  assert.strictEqual(env.timers.length, 1);
  assert.strictEqual(env.timers[0].ms, 2000);
  env.timers[0].fn();
  assert.strictEqual(el.copy.classList.contains("hidden"), false);
  assert.strictEqual(el.check.classList.contains("hidden"), true);
});

test("a click elsewhere copies nothing", () => {
  const written = [];
  const env = page({ writeText(text) { written.push(text); return Promise.resolve(); } });
  env.listeners[0].fn({ target: { closest: () => null } });
  env.listeners[0].fn({ target: null });
  assert.deepStrictEqual(written, []);
});

test("a refused or missing clipboard leaves the icons alone and does not throw", async () => {
  const refused = page({ writeText() { return Promise.reject(new Error("denied")); } });
  const el = button("X");
  refused.listeners[0].fn({ target: el });
  await new Promise((resolve) => setImmediate(resolve));
  assert.strictEqual(el.copy.classList.contains("hidden"), false);
  assert.strictEqual(refused.timers.length, 0);

  const none = page(undefined);
  none.listeners[0].fn({ target: button("Y") });
});

test("evaluating the bundle twice installs one listener and keeps the hooks global", () => {
  const env = page({ writeText() { return Promise.resolve(); } });
  env.load();
  assert.strictEqual(env.listeners.length, 1);
  assert.deepStrictEqual(Object.keys(env.window.PhoenixKitSyncHooks), []);
});
