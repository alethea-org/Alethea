import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const appJsPath = path.resolve(__dirname, "../../priv/static/assets/js/app.js");
const appJsCode = fs.readFileSync(appJsPath, "utf8");

function loadAppJs() {
  const windowListeners = {};
  let registeredHooks = null;

  const documentStub = {
    querySelectorAll(_selector) {
      return [];
    },
    querySelector(selector) {
      if (selector === "meta[name='csrf-token']") {
        return {
          getAttribute(attr) {
            return attr === "content" ? "csrf-test-token" : null;
          },
        };
      }
      return null;
    },
    getElementById(_id) {
      return null;
    },
  };

  const windowStub = {
    addEventListener(event, handler) {
      windowListeners[event] = handler;
    },
    liveSocket: null,
  };

  const LiveViewStub = {
    LiveSocket: class {
      constructor(url, socket, opts) {
        this.url = url;
        this.socket = socket;
        this.opts = opts;
        registeredHooks = opts?.hooks;
      }
      connect() {}
    },
  };

  const PhoenixStub = {
    Socket: class {},
  };

  const sandbox = {
    document: documentStub,
    window: windowStub,
    LiveView: LiveViewStub,
    Phoenix: PhoenixStub,
    console,
    Math,
  };

  vm.createContext(sandbox);
  vm.runInContext(appJsCode, sandbox);

  return {
    hooks: registeredHooks,
    window: sandbox.window,
  };
}

function createFormStub() {
  let textareaValue = "";
  const eventListeners = {
    textarea: {},
    form: {},
  };

  let submitRequested = false;

  const textarea = {
    style: { height: "" },
    get value() {
      return textareaValue;
    },
    set value(v) {
      textareaValue = v;
    },
    get scrollHeight() {
      // Single line = 36px, multi-line = 84px.
      // In a real browser, scrollHeight cannot shrink below style.height unless
      // style.height is set to "auto" first.
      const contentHeight = textareaValue.includes("\n") ? 84 : 36;
      const currentHeight = parseInt(textarea.style.height, 10);
      if (!Number.isNaN(currentHeight) && textarea.style.height !== "auto") {
        return Math.max(contentHeight, currentHeight);
      }
      return contentHeight;
    },
    addEventListener(event, handler) {
      eventListeners.textarea[event] = handler;
    },
    dispatch(event, eventObj = {}) {
      if (eventListeners.textarea[event]) {
        eventListeners.textarea[event](eventObj);
      }
    },
  };

  const submitButton = {
    type: "submit",
    disabled: false,
  };

  const form = {
    querySelector(selector) {
      if (selector === "textarea") return textarea;
      if (selector === "button[type=submit]") return submitButton;
      return null;
    },
    requestSubmit() {
      submitRequested = true;
    },
    get submitRequested() {
      return submitRequested;
    },
  };

  return { form, textarea, submitButton };
}

test("ConsultationComposer is registered in LiveSocket hooks", () => {
  const { hooks } = loadAppJs();
  assert.ok(hooks, "LiveSocket hooks object must be registered");
  assert.ok(
    hooks.ConsultationComposer,
    "ConsultationComposer hook must be present in LiveSocket hooks"
  );
  assert.equal(
    typeof hooks.ConsultationComposer.mounted,
    "function",
    "ConsultationComposer must implement mounted()"
  );
});

test("ConsultationComposer submits on Enter without Shift and respects disabled button", () => {
  const { hooks } = loadAppJs();
  const { form, textarea, submitButton } = createFormStub();
  const hook = Object.create(hooks.ConsultationComposer);
  hook.el = form;
  hook.mounted();

  // Enter with shift: should not submit
  let prevented = false;
  textarea.dispatch("keydown", {
    key: "Enter",
    shiftKey: true,
    preventDefault() {
      prevented = true;
    },
  });
  assert.equal(prevented, false, "Shift+Enter must not prevent default");
  assert.equal(form.submitRequested, false, "Shift+Enter must not submit form");

  // Enter with disabled submit button: should preventDefault but not submit
  submitButton.disabled = true;
  prevented = false;
  textarea.dispatch("keydown", {
    key: "Enter",
    shiftKey: false,
    preventDefault() {
      prevented = true;
    },
  });
  assert.equal(prevented, true, "Enter must prevent default even when disabled");
  assert.equal(form.submitRequested, false, "Enter must not submit when button is disabled");

  // Enter enabled: should submit
  submitButton.disabled = false;
  prevented = false;
  textarea.dispatch("keydown", {
    key: "Enter",
    shiftKey: false,
    preventDefault() {
      prevented = true;
    },
  });
  assert.equal(prevented, true, "Enter must prevent default");
  assert.equal(form.submitRequested, true, "Enter must call requestSubmit()");
});

test("ConsultationComposer expands height on multiline input and resets height on server patch via updated()", () => {
  const { hooks } = loadAppJs();
  const { form, textarea } = createFormStub();
  const hook = Object.create(hooks.ConsultationComposer);
  hook.el = form;

  // 1. Initial mount with empty value
  hook.mounted();
  assert.equal(textarea.style.height, "36px", "initial single-line height should be 36px");

  // 2. User types multi-line message
  textarea.value = "First line\nSecond line\nThird line";
  textarea.dispatch("input");
  assert.equal(textarea.style.height, "84px", "multiline input should expand height to 84px");

  // 3. Server patches the form on submission, clearing the textarea value
  textarea.value = "";

  // 4. LiveView lifecycle calls updated() on the hook
  assert.equal(
    typeof hook.updated,
    "function",
    "ConsultationComposer must implement updated() lifecycle callback"
  );
  hook.updated();

  // 5. Textarea height must be recalculated back to single-line height
  assert.equal(
    textarea.style.height,
    "36px",
    "textarea height must reset to single-line height after server clears value"
  );
});
