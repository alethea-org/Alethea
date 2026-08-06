// PROTOTYPE — THROWAWAY. Arrow-key cycling for the #116 variant switcher.
// Delete with prototype.css and the *_prototype_variants.ex modules.
(function () {
  function editable(el) {
    if (!el) return false;
    var tag = el.tagName;
    return (
      tag === "INPUT" ||
      tag === "TEXTAREA" ||
      tag === "SELECT" ||
      el.isContentEditable
    );
  }

  window.addEventListener("keydown", function (e) {
    if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
    if (editable(document.activeElement)) return;

    var bar = document.getElementById("prototype-switcher");
    if (!bar) return;

    window.location = bar.dataset[e.key === "ArrowLeft" ? "prev" : "next"];
  });
})();
