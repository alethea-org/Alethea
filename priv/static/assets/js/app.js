// Handle flash close
document.querySelectorAll("[role=alert][data-flash]").forEach((el) => {
  el.addEventListener("click", () => {
    el.setAttribute("hidden", "");
  });
});

// Handle modal show/hide
window.addEventListener("js:show-modal", (e) => {
  const el = document.getElementById(e.detail.id);
  if (el && el.showModal) el.showModal();
});

window.addEventListener("js:hide-modal", (e) => {
  const el = document.getElementById(e.detail.id);
  if (el && el.close) el.close();
});

// Consultation chat — keeps the thread pinned to the newest message while
// the user hasn't scrolled away (~120px tolerance).
const ConsultationScroll = {
  mounted() {
    this.stickToBottom = true;
    this.onScroll = () => {
      const el = this.el;
      this.stickToBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 120;
    };
    this.el.addEventListener("scroll", this.onScroll);
    this.el.scrollTop = this.el.scrollHeight;
  },
  updated() {
    if (this.stickToBottom) this.el.scrollTop = this.el.scrollHeight;
  },
  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll);
  },
};

// Consultation chat — composer behavior: Enter sends (Shift+Enter inserts a
// newline) and the textarea auto-grows up to 160px.
const ConsultationComposer = {
  mounted() {
    const form = this.el;
    const textarea = form.querySelector("textarea");
    if (!textarea) return;
    const submitButton = form.querySelector("button[type=submit]");

    textarea.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        if (submitButton && submitButton.disabled) return;
        form.requestSubmit();
      }
    });

    this.grow = () => {
      const el = form.querySelector("textarea");
      if (!el) return;
      el.style.height = "auto";
      el.style.height = `${Math.min(el.scrollHeight, 160)}px`;
    };
    textarea.addEventListener("input", this.grow);
    this.grow();
  },
  updated() {
    if (this.grow) this.grow();
  },
};

// Session recording — records audio in the browser with MediaRecorder and
// hands the finished file to the LiveView `:audio` upload. Buttons stay
// disabled until the server marks the hook `data-enabled="true"` (consent
// confirmed and transcription configured).
const RECORDER_MIME_TYPES = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4"];

const SessionRecorder = {
  mounted() {
    this.chunks = [];
    this.recorder = null;
    this.stream = null;
    this.elapsedMs = 0;
    this.startedAt = null;
    this.timer = null;
    this.buttons = {
      start: this.el.querySelector("[data-recorder-action=start]"),
      pause: this.el.querySelector("[data-recorder-action=pause]"),
      stop: this.el.querySelector("[data-recorder-action=stop]"),
    };
    this.elapsedEl = this.el.querySelector("[data-recorder-elapsed]");
    this.statusEl = this.el.querySelector("[data-recorder-status]");

    this.buttons.start.addEventListener("click", () => this.start());
    this.buttons.pause.addEventListener("click", () => this.togglePause());
    this.buttons.stop.addEventListener("click", () => this.stop());
    this.sync();
  },
  updated() {
    this.sync();
  },
  destroyed() {
    clearInterval(this.timer);
    if (this.recorder && this.recorder.state !== "inactive") {
      this.recorder.onstop = null;
      this.recorder.stop();
    }
    this.releaseStream();
  },
  enabled() {
    return this.el.dataset.enabled === "true" && typeof window.MediaRecorder !== "undefined";
  },
  sync() {
    const state = this.recorder ? this.recorder.state : "inactive";
    this.buttons.start.disabled = !this.enabled() || state !== "inactive";
    this.buttons.pause.disabled = state === "inactive";
    this.buttons.stop.disabled = state === "inactive";
    this.buttons.pause.textContent = state === "paused" ? "Reanudar" : "Pausar";
    if (typeof window.MediaRecorder === "undefined") {
      this.setStatus("Tu navegador no permite grabar audio. Subí un archivo.");
    }
  },
  setStatus(text) {
    if (this.statusEl) this.statusEl.textContent = text;
  },
  renderElapsed() {
    const running = this.startedAt ? Date.now() - this.startedAt : 0;
    const total = Math.floor((this.elapsedMs + running) / 1000);
    const mm = String(Math.floor(total / 60)).padStart(2, "0");
    const ss = String(total % 60).padStart(2, "0");
    this.elapsedEl.textContent = `${mm}:${ss}`;
  },
  async start() {
    if (!this.enabled()) return;
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (_error) {
      this.setStatus("No se pudo acceder al micrófono.");
      return;
    }
    const mimeType = RECORDER_MIME_TYPES.find((type) => MediaRecorder.isTypeSupported(type));
    this.recorder = new MediaRecorder(this.stream, mimeType ? { mimeType } : undefined);
    this.chunks = [];
    this.recorder.ondataavailable = (event) => {
      if (event.data && event.data.size > 0) this.chunks.push(event.data);
    };
    this.recorder.onstop = () => this.finish();
    this.recorder.start(1000);
    this.elapsedMs = 0;
    this.startedAt = Date.now();
    this.timer = setInterval(() => this.renderElapsed(), 500);
    this.setStatus("Grabando…");
    this.sync();
  },
  togglePause() {
    if (!this.recorder) return;
    if (this.recorder.state === "recording") {
      this.recorder.pause();
      this.elapsedMs += Date.now() - this.startedAt;
      this.startedAt = null;
      this.setStatus("En pausa");
    } else if (this.recorder.state === "paused") {
      this.recorder.resume();
      this.startedAt = Date.now();
      this.setStatus("Grabando…");
    }
    this.sync();
  },
  stop() {
    if (this.recorder && this.recorder.state !== "inactive") this.recorder.stop();
  },
  finish() {
    clearInterval(this.timer);
    if (this.startedAt) this.elapsedMs += Date.now() - this.startedAt;
    this.startedAt = null;
    this.renderElapsed();
    this.releaseStream();

    const type = (this.recorder.mimeType || "audio/webm").split(";")[0];
    const extension = type === "audio/mp4" ? "m4a" : "webm";
    const blob = new Blob(this.chunks, { type });
    const file = new File([blob], `sesion-${Date.now()}.${extension}`, { type });
    this.recorder = null;
    this.chunks = [];
    this.sync();

    if (!this.enabled()) {
      this.setStatus("Confirmá el consentimiento antes de guardar la grabación.");
      return;
    }
    this.setStatus("Subiendo la grabación…");
    this.upload("audio", [file]);
  },
  releaseStream() {
    if (this.stream) this.stream.getTracks().forEach((track) => track.stop());
    this.stream = null;
  },
};

// LiveView Setup
let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { ConsultationScroll, ConsultationComposer, SessionRecorder },
});

// Page loading indicator — a centered spinner shown while LiveView
// navigates. It only appears after a short delay so fast loads don't flash.
const PAGE_LOADER_DELAY_MS = 250;
let pageLoaderTimer = null;

const pageLoader = () => {
  let el = document.getElementById("page-loader");
  if (!el) {
    el = document.createElement("div");
    el.id = "page-loader";
    el.className = "page-loader";
    el.setAttribute("role", "status");
    el.setAttribute("aria-live", "polite");
    el.innerHTML = '<span class="page-loader__spinner" aria-hidden="true"></span><span class="sr-only">Cargando…</span>';
    document.body.appendChild(el);
  }
  return el;
};

window.addEventListener("phx:page-loading-start", () => {
  clearTimeout(pageLoaderTimer);
  pageLoaderTimer = setTimeout(() => pageLoader().classList.add("is-visible"), PAGE_LOADER_DELAY_MS);
});

window.addEventListener("phx:page-loading-stop", () => {
  clearTimeout(pageLoaderTimer);
  const el = document.getElementById("page-loader");
  if (el) el.classList.remove("is-visible");
});

// Connect if there are any LiveViews on the page
liveSocket.connect();

// Expose liveSocket on window for debugging
window.liveSocket = liveSocket;
