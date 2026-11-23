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

// Session recording (session-recording S2) — records mono Opus with
// MediaRecorder and streams it to the LiveView while recording: "start"
// creates the recording, every ~10 s chunk is sent base64 as "chunk" and
// waits for its ack, and "finish" hands it to transcription once every chunk
// was acknowledged. Unacked chunks stay queued and are resent in order after
// a reconnect (seq N+1 is never sent before N is acked), so a lost
// connection loses nothing already recorded. Buttons stay disabled until the
// server marks the hook `data-enabled="true"` (consent confirmed and
// transcription configured).
const RECORDER_MIME_TYPES = ["audio/webm;codecs=opus", "audio/mp4"];
const RECORDER_TIMESLICE_MS = 10_000;
const RECORDER_BITRATE = 24_000;
const RECORDER_PERMANENT_ERRORS = ["not_recording", "chunk_too_large", "recording_too_long"];

const formatClock = (ms) => {
  const total = Math.floor(ms / 1000);
  const mm = String(Math.floor(total / 60)).padStart(2, "0");
  const ss = String(total % 60).padStart(2, "0");
  return `${mm}:${ss}`;
};

const blobToBase64 = (blob) =>
  new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(",", 2)[1] || "");
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });

const SessionRecorder = {
  mounted() {
    this.generation = 0;
    this.resetSession();
    this.buttons = {
      start: this.el.querySelector("[data-recorder-action=start]"),
      pause: this.el.querySelector("[data-recorder-action=pause]"),
      stop: this.el.querySelector("[data-recorder-action=stop]"),
    };
    this.elapsedEl = this.el.querySelector("[data-recorder-elapsed]");
    this.savedEl = this.el.querySelector("[data-recorder-saved]");
    this.statusEl = this.el.querySelector("[data-recorder-status]");

    this.buttons.start.addEventListener("click", () => this.start());
    this.buttons.pause.addEventListener("click", () => this.togglePause());
    this.buttons.stop.addEventListener("click", () => this.stop());
    this.onBeforeUnload = (event) => {
      if (!this.recordingId) return;
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", this.onBeforeUnload);
    this.sync();
  },
  updated() {
    this.sync();
  },
  reconnected() {
    // In-flight pushes may be lost on disconnect; resend from the head.
    this.generation += 1;
    this.sending = false;
    this.flush();
  },
  destroyed() {
    clearInterval(this.timer);
    window.removeEventListener("beforeunload", this.onBeforeUnload);
    if (this.recorder && this.recorder.state !== "inactive") {
      this.recorder.ondataavailable = null;
      this.recorder.onstop = null;
      this.recorder.stop();
    }
    this.releaseStream();
  },
  resetSession() {
    this.recorder = null;
    this.stream = null;
    this.recordingId = null;
    this.queue = [];
    this.nextSeq = 0;
    this.sending = false;
    this.stopped = false;
    this.finishing = false;
    this.failed = false;
    this.elapsedMs = 0;
    this.startedAt = null;
    this.savedMs = 0;
    this.timer = null;
  },
  enabled() {
    return this.el.dataset.enabled === "true" && typeof window.MediaRecorder !== "undefined";
  },
  sync() {
    const state = this.recorder ? this.recorder.state : "inactive";
    const busy = this.recordingId !== null;
    this.buttons.start.disabled = !this.enabled() || busy;
    this.buttons.pause.disabled = state === "inactive";
    this.buttons.stop.disabled = state === "inactive";
    this.buttons.pause.textContent = state === "paused" ? "Reanudar" : "Pausar";
    if (typeof window.MediaRecorder === "undefined") {
      this.setStatus("Tu navegador no permite grabar audio.");
    }
  },
  setStatus(text) {
    if (this.statusEl) this.statusEl.textContent = text;
  },
  currentElapsed() {
    return this.elapsedMs + (this.startedAt ? Date.now() - this.startedAt : 0);
  },
  renderClock() {
    this.elapsedEl.textContent = formatClock(this.currentElapsed());
    if (this.savedEl) {
      this.savedEl.textContent = this.recordingId ? `guardado hasta ${formatClock(this.savedMs)}` : "";
    }
  },
  push(event, payload) {
    return new Promise((resolve) => this.pushEvent(event, payload, (reply) => resolve(reply)));
  },
  async start() {
    if (!this.enabled() || this.recordingId) return;
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true },
      });
    } catch (_error) {
      this.setStatus("No se pudo acceder al micrófono.");
      return;
    }
    const mimeType = RECORDER_MIME_TYPES.find((type) => MediaRecorder.isTypeSupported(type));
    if (!mimeType) {
      this.releaseStream();
      this.setStatus("Tu navegador no permite grabar en un formato admitido.");
      return;
    }
    const reply = await this.push("start", { content_type: mimeType });
    if (!reply || !reply.id) {
      this.releaseStream();
      this.setStatus("No se pudo iniciar la grabación.");
      return;
    }
    this.recordingId = reply.id;
    this.recorder = new MediaRecorder(this.stream, {
      mimeType,
      audioBitsPerSecond: RECORDER_BITRATE,
    });
    this.recorder.ondataavailable = (event) => {
      if (!event.data || event.data.size === 0) return;
      // Recorded time up to the end of this chunk, for the saved indicator.
      this.queue.push({ seq: this.nextSeq++, blob: event.data, untilMs: this.currentElapsed() });
      this.flush();
    };
    this.recorder.onstop = () => {
      this.stopped = true;
      this.releaseStream();
      this.maybeFinish();
    };
    this.recorder.start(RECORDER_TIMESLICE_MS);
    this.elapsedMs = 0;
    this.startedAt = Date.now();
    this.timer = setInterval(() => this.renderClock(), 500);
    this.setStatus("Grabando…");
    this.renderClock();
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
    if (!this.recorder || this.recorder.state === "inactive") return;
    if (this.startedAt) this.elapsedMs += Date.now() - this.startedAt;
    this.startedAt = null;
    this.setStatus("Guardando el audio pendiente…");
    this.recorder.stop();
    this.sync();
  },
  // Sends queued chunks one at a time, in order. A chunk leaves the queue
  // only once the server acknowledged it. A push in flight when the socket
  // drops may never reply; `reconnected()` bumps the generation so that
  // stale loop stops and a fresh one resends from the head of the queue.
  async flush() {
    if (this.sending || this.failed || !this.recordingId) return;
    const generation = this.generation;
    this.sending = true;
    while (this.queue.length > 0 && !this.failed) {
      const chunk = this.queue[0];
      if (!chunk.data) chunk.data = await blobToBase64(chunk.blob);
      if (generation !== this.generation) return;
      const reply = await this.push("chunk", {
        id: this.recordingId,
        seq: chunk.seq,
        data: chunk.data,
      });
      if (generation !== this.generation) return;
      if (reply && reply.ok) {
        if (this.queue[0] === chunk) this.queue.shift();
        this.savedMs = Math.max(this.savedMs, chunk.untilMs);
        this.renderClock();
      } else if (reply && RECORDER_PERMANENT_ERRORS.includes(reply.error)) {
        this.failed = true;
        this.setStatus("El servidor dejó de aceptar audio para esta grabación.");
        if (this.recorder && this.recorder.state !== "inactive") this.recorder.stop();
      } else {
        // Transient error: retry on the next chunk or after a reconnect.
        break;
      }
    }
    this.sending = false;
    this.maybeFinish();
  },
  async maybeFinish() {
    if (!this.stopped || this.finishing || this.sending) return;
    if (this.queue.length > 0 && !this.failed) return;
    this.finishing = true;
    clearInterval(this.timer);
    const reply = await this.push("finish", { id: this.recordingId });
    if (reply && reply.ok) {
      this.setStatus("");
      this.resetSession();
      this.elapsedEl.textContent = "00:00";
      this.renderClock();
    } else {
      // The cleanup job finalizes the recording if this never succeeds.
      this.finishing = false;
      this.setStatus("No se pudo finalizar. Se procesará automáticamente.");
      this.resetSession();
    }
    this.sync();
  },
  releaseStream() {
    if (this.stream) this.stream.getTracks().forEach((track) => track.stop());
    this.stream = null;
  },
};

// Billing — Paddle.js overlay checkout (#453). Loads Paddle.js once, fills
// each plan card with its localized price, and opens checkout in Spanish.
// Completing checkout only tells the server to show a "processing" state;
// access is granted by the verified Paddle webhook, never by the browser.
const PADDLE_JS_URL = "https://cdn.paddle.com/paddle/v2/paddle.js";
let paddleReady = null;

const loadPaddle = (config) => {
  if (paddleReady) return paddleReady;
  paddleReady = new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = PADDLE_JS_URL;
    script.async = true;
    script.onload = () => {
      if (config.environment === "sandbox") window.Paddle.Environment.set("sandbox");
      window.Paddle.Initialize({
        token: config.client_token,
        eventCallback: (event) => {
          if (event.name === "checkout.completed" && window.__paddleCheckoutHook) {
            window.__paddleCheckoutHook.pushEvent("checkout_completed", {});
          }
        },
      });
      resolve(window.Paddle);
    };
    script.onerror = () => {
      paddleReady = null;
      reject(new Error("paddle.js failed to load"));
    };
    document.head.appendChild(script);
  });
  return paddleReady;
};

const PaddleCheckout = {
  mounted() {
    this.config = JSON.parse(this.el.dataset.config);
    window.__paddleCheckoutHook = this;

    this.onClick = (e) => {
      const button = e.target.closest("[data-checkout]");
      if (!button) return;
      loadPaddle(this.config)
        .then((Paddle) =>
          Paddle.Checkout.open({
            items: [{ priceId: button.dataset.checkout, quantity: 1 }],
            customer: { email: this.config.email },
            customData: this.config.custom_data,
            settings: { displayMode: "overlay", locale: "es" },
          })
        )
        .catch(() => this.pushEvent("checkout_failed", {}));
    };
    this.el.addEventListener("click", this.onClick);

    loadPaddle(this.config)
      .then((Paddle) =>
        Paddle.PricePreview({
          items: this.config.price_ids.map((priceId) => ({ priceId, quantity: 1 })),
        })
      )
      .then((result) => this.fillPrices(result))
      .catch(() => {});
  },
  fillPrices(result) {
    const lineItems = result?.data?.details?.lineItems || [];
    lineItems.forEach((item) => {
      const card = this.el.querySelector(`[data-price-id="${item.price?.id}"]`);
      if (!card) return;
      const name = item.price?.name || item.product?.name;
      if (name) card.querySelector("[data-price-name]").textContent = name;
      const total = item.formattedTotals?.total;
      if (total) card.querySelector("[data-price-total]").textContent = total;
      const cycle = item.price?.billingCycle;
      if (cycle) {
        const units = {
          day: ["día", "días"],
          week: ["semana", "semanas"],
          month: ["mes", "meses"],
          year: ["año", "años"],
        };
        const [one, many] = units[cycle.interval] || [cycle.interval, cycle.interval];
        card.querySelector("[data-price-cycle]").textContent =
          cycle.frequency === 1 ? `por ${one}` : `cada ${cycle.frequency} ${many}`;
      }
    });
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick);
    if (window.__paddleCheckoutHook === this) window.__paddleCheckoutHook = null;
  },
};

// LiveView Setup
let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { ConsultationScroll, ConsultationComposer, PaddleCheckout, SessionRecorder },
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
