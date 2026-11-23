# Landing redesign (promotional, proyectoMed-style)

Objective: a modern public landing at `/` that lets a psychologist understand everything Alethea does, for them and for their patients, without a live pitch. Branch `feat/landing-redesign` (from `main`). Delivery: ask-on-risk. Runner: `mix test` / `mix precommit`.

## Specs

- S1 (revised by L9-L11): Alethea's own design system (editorial.css tokens, white background), not proyectoMed's look; only the dynamic-web idea is borrowed. Pinned scroll story on wide screens: one short beat at a time, mockup parts appear per beat (`data-at`), light parallax; flow layout on narrow screens, reduced motion and no JS. Original wording: Look and feel "parecida a la que tenemos en proyectoMed, o sea más moderna": dark page, scroll-driven scenes with a sticky visual, numbered scenes with section dots, reveal animations, phone-first layout, reduced-motion respected, works without JS. proyectoMed's Unreal clips do not exist for Alethea, so visuals are HTML mockups of the real UI (crisp, accessible, no heavy media).
- S2: "quiero que seas bien estricto en mostrar todo lo que la app hace y de qué le serviría a un psicólogo y a sus pacientes." Only claims verified in code (inventory 2026-11-20). Each scene states the benefit for the professional and, where relevant, for the patient.
- S3: Scenes (verified features):
  1. Invitación por Telegram (link + código, sin app ni contraseña).
  2. Diario con IA y triggers: "te faltó en el diario con IA hablar de que el profesional puede programar los triggers activos y reactivos". Active = scheduled one-off/daily/weekly, AI drafts, professional approves; reactive = matched topic folded naturally into the reply; every firing logged with its message. Patient can `/pausa`.
  3. Análisis de emociones por mensaje (alegría, tristeza, enojo, miedo, neutral) + 7-day trend.
  4. Detección de crisis: professional's preset containment message, in-app alert, patient sorted to top. No email/Telegram/24-7 claims.
  5. Briefing semanal auto 2h before the session: status level + anxiety, social, crisis, sessions metrics.
  6. Chat con la historia clínica (RAG) — star feature: "el profesional puede hablar con la IA de material real (mensajes, notas clínicas, análisis funcionales, etc)". Cites sources, marks hypotheses.
  7. Análisis funcional E-O-R-C: target behaviors, cited evidence, AI proposals accept/edit/discard, versions, spontaneous vs elicited.
  8. Notas clínicas inmutables y auditadas; risk on/off through notes.
  9. Privacidad: per-patient key, decrypt on demand + audited, isolation between professionals, patient never sees clinical data.
- S4: Recorded sessions scene: "una sección para que se puedan grabar las sesiones de terapia y que la sesión vaya guardando en el Rag del paciente toda la sesión ... ¿de qué hablamos la sesión pasada?" Shown as available (L6).
- S6: Waitlist: "que se puedan anotar a una lista de espera para el lanzamiento de la app al final de todo, en el lugar de los planes". Name + email stored (unique email, honeypot); primary CTAs point to it.
- S5 (relaxed by L6): originally must not claim: per-patient bot personality, voice/audio, crisis alerts outside the app, exports, "every data point links to its message", "no third party ever processes data", pricing (undecided, #505).

## Tasks

- T1 S1-S6 landing template + landing.css + landing.js + waitlist (migration, context, controller) + tests — inline — done (5 landing/waitlist tests; full suite 2910 passed, 5 skipped)

## Log

- L1 (2026-11-20) "podemos ver la landing page y hacerle varios cambios?? me gustaría que la landing page sea parecida a la que tenemos en proyectoMed, o sea más moderna. Así podemos empezar a promocionar la app. Porque se la estoy compartiendo a psicólogos, pero no tengo forma de vendérsela sin mi voz, quisiera que si le paso la landing page puedan ver todo lo que hace la app y el potencial que tiene."
- L2 "pero hay varias cosas que no muestra en el video, por ejemplo que cada mensaje pasa por un análisis de emociones, no sé, quiero que seas bien estricto en mostrar todo lo que la app hace y de qué le serviría a un psicólogo y a sus pacientes."
- L3 "el chat de Rag del paciente es genial. O sea, el profesional puede hablar con la IA de material real (mensajes, notas clínicas, análisis funcionales, etc). Y hagamos algo que todavía la app no hace, pero que estaría bueno ponerlo en la promoción, y es que haya una sección para que se puedan grabar las sesiones de terapia y que la sesión vaya guardando en el Rag del paciente toda la sesión, o sea la conversación entre paciente y profesional. Esto ayuda al profesional porque podrá preguntar, ¿de qué hablamos la sesión pasada?"
- L4 "te faltó en el diario con IA hablar de que el profesional puede programar los triggers activos y reactivos"
- L5 Code inventory: emotion analysis, reactive triggers and RAG depend on env flags not set in prod (EMOTION_ANALYZER_ENABLED, TRIGGER_MATCHER_ENABLED, EMBEDDINGS_ENABLED). Separate security gap: /admin/oban-dashboard open to any professional.
- L6 "no importa aquellas cosas que no hace mostrarlas como si las hace, porque las vamos a terminar de desarrollar." → recorded sessions moved from "Próximamente" to a regular scene.
- L7 "me gustaría agregar que se puedan anotar a una lista de espera para el lanzamiento de la app al final de todo, en el lugar de los planes"
- L8 Tests written after code. Visual check pending (no local browser; installing Playwright Chromium in scratchpad).
- L9 "lo hiciste con otro estilo que no es de la app, tomaste demasiado del ProyectoMEd, solo quería la idea de web dinámica" / "me gustaría que fuera fondo blanco también"
- L10 "está todo muy separado entre sección y sección, pero en cada sección todo está muy pegado ... capaz hacer un parallax o algo que haga que se vaya avanzando y profundizando en lo que hace la app. Pero que no aparezca mucho texto de una vez, más bien que vaya apareciendo poco texto a medida que vas scrolleando. Como un buen storytelling"
- L11 Trigger example per user: active = "le recuerda que tiene que hacer la tarea que charlaron el martes" and "ahora que está por entrar al examen se acuerde del cuento del gigante y el enano". Also: nav button text invisible and tight spacing were one bug (`.lx a` / `.lx p` resets outranking component rules; now `:where()`); waitlist redesigned ("está mal hecha y no llama a nadie"); scenes enlarged ("cada sección ocupa muy poco espacio").
- L12 Visual check with headless Chromium (Playwright in scratchpad, zip extracted by hand: its installer hangs on Node 26): desktop 1710x985 every scene at last beat, mobile 390px full page, no horizontal overflow.
- L13 (2026-11-23) "a mí me gustaría poder mergear a main todo, pero lo más importante la landing page. Para que pueda empezar a hacerle propaganda. Pero para eso sería bueno que lo de ponerse en la lista de espera realmente funcione." Decisions: "Private in-app page (Recommended)" for seeing signups; production stays off ("Not yet").
- L14 Added `/admin/waitlist` (list, newest first, total) and `/admin/waitlist.csv` (quoted, formula-safe), gated by `ADMIN_EMAILS`; non-admins get the 404 page. 7 tests.
