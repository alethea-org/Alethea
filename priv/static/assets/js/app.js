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
  hooks: { ConsultationScroll, ConsultationComposer, PaddleCheckout },
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
