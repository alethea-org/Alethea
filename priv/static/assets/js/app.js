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

// LiveView Setup
let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: { _csrf_token: csrfToken },
});

// Connect if there are any LiveViews on the page
liveSocket.connect();

// Expose liveSocket on window for debugging
window.liveSocket = liveSocket;
