import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const appJsCode = fs.readFileSync(
  path.resolve(__dirname, "../../priv/static/assets/js/app.js"),
  "utf8",
);

function makeElement(tag) {
  const classes = new Set();
  return {
    tagName: tag.toUpperCase(),
    id: "",
    innerHTML: "",
    attributes: {},
    children: [],
    classList: {
      add: (c) => classes.add(c),
      remove: (c) => classes.delete(c),
      contains: (c) => classes.has(c),
    },
    set className(value) {
      classes.clear();
      value.split(/\s+/).filter(Boolean).forEach((c) => classes.add(c));
    },
    get className() {
      return [...classes].join(" ");
    },
    setAttribute(name, value) {
      this.attributes[name] = value;
    },
    appendChild(child) {
      this.children.push(child);
      return child;
    },
  };
}

function loadAppJs() {
  const listeners = {};
  const timers = [];
  const body = makeElement("body");

  const document = {
    body,
    querySelector: (selector) =>
      selector === "meta[name='csrf-token']" ? { getAttribute: () => "token" } : null,
    querySelectorAll: () => [],
    getElementById: (id) => body.children.find((el) => el.id === id) || null,
    createElement: makeElement,
  };

  const window = {
    addEventListener: (event, handler) => {
      listeners[event] = handler;
    },
  };

  const sandbox = {
    document,
    window,
    console,
    Math,
    LiveView: { LiveSocket: class { connect() {} } },
    Phoenix: { Socket: class {} },
    setTimeout: (fn, ms) => timers.push({ fn, ms }) && timers.length,
    clearTimeout: () => {},
  };

  vm.createContext(sandbox);
  vm.runInContext(appJsCode, sandbox);

  const runTimers = () => timers.splice(0).forEach((t) => t.fn());
  const fire = (event) => listeners[event]({ detail: {} });
  return { body, fire, runTimers, timers };
}

test("navigation shows a thin top progress bar, not a full-page overlay", () => {
  const { body, fire, runTimers } = loadAppJs();

  fire("phx:page-loading-start");
  runTimers();

  const loader = body.children.find((el) => el.id === "page-loader");
  assert.ok(loader, "page loader element is created");
  assert.ok(loader.classList.contains("page-loader"));
  assert.ok(loader.classList.contains("is-visible"));
  assert.match(loader.innerHTML, /page-loader__bar/);
  assert.doesNotMatch(loader.innerHTML, /page-loader__spinner/);
  assert.equal(loader.attributes.role, "progressbar");
});

test("the bar appears after a short delay so fast navigations don't flash it", () => {
  const { timers, fire } = loadAppJs();

  fire("phx:page-loading-start");

  assert.equal(timers.length, 1);
  assert.ok(timers[0].ms > 0 && timers[0].ms <= 150, `delay was ${timers[0].ms}ms`);
});

test("loading stop hides the bar", () => {
  const { body, fire, runTimers } = loadAppJs();

  fire("phx:page-loading-start");
  runTimers();
  fire("phx:page-loading-stop");

  const loader = body.children.find((el) => el.id === "page-loader");
  assert.ok(!loader.classList.contains("is-visible"));
});
