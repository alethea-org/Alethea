// Alethea · public landing (GET /).
//
// Progressive enhancement only — the page is a complete document without it.
//
// Pin mode (wide, tall-enough viewport, motion allowed): `html.lx-pin` makes
// each `[data-scene]` taller than the viewport with a sticky stage inside. The
// scroll position inside a scene picks its current beat; the beat's text and
// every mockup part whose `data-at` has been reached get `.is-on`. `--p`
// (scene progress, 0 → 1) and `--hp` (hero progress) feed the CSS parallax.
//
// Flow mode (everything else): scenes are ordinary sections that fade in once.
//
// Always: side dots follow the scene at the viewport centre, and the top bar
// shows how far down the page the reader is.
(() => {
  const root = document.getElementById("landing");
  if (!root) return;

  const html = document.documentElement;
  const hero = root.querySelector(".lx-hero");
  const tour = root.querySelector(".lx-tour");
  const dotsNav = root.querySelector(".lx-dots");
  const bar = root.querySelector("[data-progress]");
  const dots = new Map([...root.querySelectorAll("[data-dot]")].map((d) => [d.dataset.dot, d]));

  const scenes = [...root.querySelectorAll("[data-scene]")].map((el) => ({
    el,
    beats: [...el.querySelectorAll("[data-beat]")],
    ticks: [...el.querySelectorAll("[data-tick]")],
    parts: [...el.querySelectorAll("[data-at]")].map((part) => [part, Number(part.dataset.at)]),
    // Top-level mockup pieces with every beat that touches them, for the
    // phone layout, which shows one piece at a time.
    pieces: [...el.querySelectorAll(".lx-stage__visual > *")].map((piece) => ({
      el: piece,
      ats: [piece, ...piece.querySelectorAll("[data-at]")]
        .map((node) => Number(node.dataset.at))
        .filter((at) => at > 0),
    })),
    beat: -1,
  }));

  // Phone story: one invisible snap point per beat, so each swipe lands on
  // exactly one sentence however hard the finger flicks. A scene is
  // `100svh + beats * 70svh` tall (landing.css), so beat i owns the scroll
  // range starting at (i - 1) * 70svh; points after the first sit 10svh into
  // their range to stay clear of the boundary. The CSS only turns them on in
  // `html.lx-pin-narrow`.
  // One more point halfway through the hand-over to the next section keeps
  // every gap shorter than a swipe, so mandatory snapping never pulls the
  // reader back to the last beat.
  scenes.forEach(({ el, beats }) => {
    const tops = beats.map((_, i) => (i === 0 ? "0px" : `calc(${i} * 70svh + 10svh)`));
    tops.push(`calc(${beats.length} * 70svh + 30svh)`);
    tops.forEach((top) => {
      const point = document.createElement("i");
      point.className = "lx-snap";
      point.setAttribute("aria-hidden", "true");
      point.style.top = top;
      el.append(point);
    });
  });

  const wide = window.matchMedia("(min-width: 1100px) and (min-height: 640px)");
  // Phones and tablets in portrait get the story too, stacked vertically.
  const narrow = window.matchMedia("(max-width: 1099px) and (min-height: 560px)");
  const calm = window.matchMedia("(prefers-reduced-motion: reduce)");
  let pinned = false;

  const setBeat = (scene, beat) => {
    if (scene.beat === beat) return;
    scene.beat = beat;
    scene.beats.forEach((el, i) => {
      el.classList.toggle("is-on", i + 1 === beat);
      el.classList.toggle("is-past", i + 1 < beat);
    });
    scene.ticks.forEach((el, i) => el.classList.toggle("is-on", i + 1 === beat));
    scene.parts.forEach(([el, at]) => el.classList.toggle("is-on", at <= beat));

    // Phone layout: focus the piece holding the newest revealed part (the
    // later piece wins a tie), so the visual follows the sentence.
    let focus = scene.pieces[0];
    let newest = 0;
    scene.pieces.forEach((piece) => {
      const reached = piece.ats.filter((at) => at <= beat);
      const top = reached.length ? Math.max(...reached) : 0;
      if (top >= newest && top > 0) {
        newest = top;
        focus = piece;
      }
    });
    scene.pieces.forEach((piece) => piece.el.classList.toggle("is-focus", piece === focus));
  };

  // The beat a scene is on, from how far its top has travelled past the
  // viewport top. Beat 1 switches on a little before the stage pins, so the
  // reader never meets an empty stage.
  const measure = (scene, vh) => {
    const rect = scene.el.getBoundingClientRect();
    const count = scene.beats.length;
    const travel = rect.height - vh;
    if (rect.top > vh * 0.55) return { beat: 0, progress: 0 };
    if (travel <= 0 || rect.top > 0) return { beat: 1, progress: 0 };
    const progress = Math.min(1, -rect.top / travel);
    return { beat: Math.min(count, Math.floor(progress * count) + 1), progress };
  };

  const frame = () => {
    ticking = false;
    const vh = window.innerHeight;

    if (bar) {
      const max = html.scrollHeight - vh;
      bar.style.transform = `scaleX(${max > 0 ? Math.min(1, window.scrollY / max) : 0})`;
    }
    if (!pinned) return;

    if (hero) hero.style.setProperty("--hp", Math.min(1, window.scrollY / vh).toFixed(3));
    scenes.forEach((scene) => {
      const { beat, progress } = measure(scene, vh);
      setBeat(scene, beat);
      scene.el.style.setProperty("--p", progress.toFixed(3));
    });
  };

  let ticking = false;
  const schedule = () => {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(frame);
  };

  const setMode = () => {
    pinned = (wide.matches || narrow.matches) && !calm.matches;
    html.classList.toggle("lx-pin", pinned);
    html.classList.toggle("lx-pin-narrow", pinned && narrow.matches);
    if (!pinned) {
      scenes.forEach((scene) => {
        scene.beat = -1;
        [...scene.beats, ...scene.ticks, ...scene.parts.map(([el]) => el)].forEach((el) =>
          el.classList.remove("is-on", "is-past"),
        );
        scene.pieces.forEach((piece) => piece.el.classList.remove("is-focus"));
      });
    }
    schedule();
  };

  wide.addEventListener("change", setMode);
  narrow.addEventListener("change", setMode);
  calm.addEventListener("change", setMode);
  window.addEventListener("scroll", schedule, { passive: true });
  window.addEventListener("resize", schedule);
  setMode();

  const reveal = (el) => el.classList.add("is-in");

  if (!("IntersectionObserver" in window)) {
    [hero, ...scenes.map((s) => s.el)].forEach((el) => el && reveal(el));
    return;
  }

  requestAnimationFrame(() => hero && reveal(hero));

  const revealer = new IntersectionObserver(
    (entries) =>
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        reveal(entry.target);
        revealer.unobserve(entry.target);
      }),
    { rootMargin: "0px 0px -15% 0px", threshold: 0.05 },
  );

  const centre = new IntersectionObserver(
    (entries) =>
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        dots.forEach((dot, id) => {
          if (id === entry.target.id) dot.setAttribute("aria-current", "true");
          else dot.removeAttribute("aria-current");
        });
      }),
    { rootMargin: "-50% 0px -50% 0px", threshold: 0 },
  );

  scenes.forEach(({ el }) => {
    revealer.observe(el);
    centre.observe(el);
  });

  if (tour && dotsNav) {
    new IntersectionObserver(
      ([entry]) => dotsNav.classList.toggle("is-visible", entry.isIntersecting),
      { rootMargin: "-40% 0px -40% 0px" },
    ).observe(tour);
  }
})();
