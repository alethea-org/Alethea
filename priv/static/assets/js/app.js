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

    const grow = () => {
      textarea.style.height = "auto";
      textarea.style.height = `${Math.min(textarea.scrollHeight, 160)}px`;
    };
    textarea.addEventListener("input", grow);
    grow();
  },
};

// LiveView Setup
let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { ConsultationScroll, ConsultationComposer },
});

// Connect if there are any LiveViews on the page
liveSocket.connect();

// Expose liveSocket on window for debugging
window.liveSocket = liveSocket;
