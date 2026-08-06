defmodule AletheaWeb.Components.PagePrototypeVariants do
  @moduledoc """
  PROTOTYPE — THROWAWAY. Landing / onboarding entry variants for
  wayfinder ticket #116 ("Layout & visual disposition: dashboard +
  onboarding").

  Three structurally different takes on `/`, mounted on the real route
  via `?variant=`:

    * `a` — Editorial: two-column hero, left-aligned, muted clinical
      palette, one CTA, a product shot beside the copy, and three
      numbered columns instead of a six-card feature grid.
    * `b` — Product first: the dashboard mock carries the hero, the copy
      collapses to a three-item checklist, and a stat strip replaces the
      marketing band.
    * `c` — Single screen: dark, one viewport, the Telegram onboarding
      path as three steps, no feature grid at all.

  All three also fix the stale WhatsApp copy — patient journaling moved
  to Telegram in #87.

  No tests, no error handling, no abstraction — pick a direction, then
  delete this module.
  """
  use AletheaWeb, :html

  # ── Variant A — Editorial ─────────────────────────────────────────

  def variant_a(assigns) do
    ~H"""
    <div class="ptl">
      <div class="ptl-shell">
        <nav class="ptl-nav">
          <.link navigate={~p"/"} class="ptl-brand">
            <span class="ptl-brand__mark">
              <img src={~p"/images/logo.svg"} alt="" width="16" />
            </span>
            Alethea
          </.link>
          <div class="ptl-navlinks">
            <.link navigate={~p"/login"} class="ptl-link">Iniciar sesión</.link>
            <.link navigate={~p"/register"} class="ptl-cta ptl-cta--sm">Crear cuenta</.link>
          </div>
        </nav>

        <section class="ptla-hero">
          <div>
            <p class="pt-eyebrow" style="margin-bottom:14px;">Diario clínico entre sesiones</p>
            <h1 class="ptla-title">
              Llegá a la sesión sabiendo cómo estuvo la semana.
            </h1>
            <p class="ptla-lede">
              Tu paciente escribe por Telegram cuando lo necesita. Alethea analiza el
              registro y te entrega un resumen semanal con métricas, listo para leer
              antes del encuentro.
            </p>
            <div class="ptla-actions">
              <.link navigate={~p"/register"} class="ptl-cta">Crear cuenta</.link>
              <.link navigate={~p"/login"} class="ptl-cta ptl-cta--ghost">Ya tengo cuenta</.link>
            </div>
            <p class="ptla-proof">
              Cada paciente tiene su propia clave de cifrado. Ni el equipo de Alethea
              ni terceros pueden leer el contenido clínico.
            </p>
          </div>

          <div class="ptla-shot" aria-hidden="true">
            <div class="ptla-shot__bar">
              <span class="ptla-shot__dot"></span>
              <span class="ptla-shot__dot"></span>
              <span class="ptla-shot__dot"></span>
            </div>
            <div class="ptla-shot__body">
              <div class="ptla-shot__line" style="width:45%;"></div>
              <div class="ptla-shot__line" style="width:85%;"></div>
              <div class="ptla-shot__line" style="width:70%;"></div>
              <div class="ptla-shot__bars">
                <i style="height:38%;"></i>
                <i style="height:64%;"></i>
                <i style="height:48%;"></i>
                <i style="height:88%;"></i>
                <i style="height:56%;"></i>
                <i style="height:72%;"></i>
                <i style="height:40%;"></i>
              </div>
            </div>
          </div>
        </section>
      </div>

      <section class="ptla-band">
        <div class="ptl-shell ptla-cols">
          <div class="ptla-col">
            <span class="ptla-num">01</span>
            <h3>Invitás al paciente</h3>
            <p>
              Generás un enlace de Telegram desde el panel. El paciente entra sin app,
              sin usuario y sin contraseña.
            </p>
          </div>
          <div class="ptla-col">
            <span class="ptla-num">02</span>
            <h3>Escribe durante la semana</h3>
            <p>
              La IA acompaña con un tono clínicamente neutro y distingue lo espontáneo
              de lo elicitado en el registro.
            </p>
          </div>
          <div class="ptla-col">
            <span class="ptla-num">03</span>
            <h3>Leés el resumen</h3>
            <p>
              Resumen semanal con métricas emocionales y alertas de riesgo, con enlace
              al mensaje que originó cada insight.
            </p>
          </div>
        </div>
      </section>

      <footer
        class="ptl-shell"
        style="padding-top:28px; padding-bottom:28px; font-size:13px; color:#667085;"
      >
        Alethea — Centro de Control Clínico · Cifrado por paciente
      </footer>
    </div>
    """
  end

  # ── Variant B — Product first ─────────────────────────────────────

  def variant_b(assigns) do
    ~H"""
    <div class="ptl">
      <div class="ptl-shell">
        <nav class="ptl-nav">
          <.link navigate={~p"/"} class="ptl-brand">
            <span class="ptl-brand__mark">
              <img src={~p"/images/logo.svg"} alt="" width="16" />
            </span>
            Alethea
          </.link>
          <div class="ptl-navlinks">
            <.link navigate={~p"/login"} class="ptl-link">Iniciar sesión</.link>
            <.link navigate={~p"/register"} class="ptl-cta ptl-cta--sm">Crear cuenta</.link>
          </div>
        </nav>

        <section class="ptlb-hero">
          <div>
            <span class="ptlb-badge">Cifrado por paciente</span>
            <h1 class="ptlb-title">El panel que resume la semana de cada paciente.</h1>
            <p class="pt-muted" style="font-size:16px;">
              Journaling por Telegram, análisis emocional y un resumen listo para tu sesión.
            </p>

            <ul class="ptlb-checks">
              <li>
                <span class="ptlb-tick">&#10003;</span>
                <span>
                  <b>Resumen semanal por paciente</b>
                  Métricas emocionales y evolución de los últimos 7 días.
                </span>
              </li>
              <li>
                <span class="ptlb-tick">&#10003;</span>
                <span>
                  <b>Alertas de riesgo</b>
                  El sistema marca al paciente que necesita intervención prioritaria.
                </span>
              </li>
              <li>
                <span class="ptlb-tick">&#10003;</span>
                <span>
                  <b>Historial descifrable bajo demanda</b>
                  El contenido clínico se abre solo cuando vos lo pedís.
                </span>
              </li>
            </ul>

            <.link navigate={~p"/register"} class="ptl-cta">Crear cuenta</.link>
          </div>

          <div class="ptlb-mock" aria-hidden="true">
            <div class="ptlb-mock__top">
              <span class="pt-avatar" style="width:26px; height:26px; font-size:10px;">AL</span>
              <span style="font-size:13px; font-weight:600;">Centro de Control</span>
            </div>
            <div class="ptlb-mock__grid">
              <div class="ptlb-mock__rail">
                <span class="ptlb-mock__railitem ptlb-mock__railitem--on"></span>
                <span class="ptlb-mock__railitem"></span>
                <span class="ptlb-mock__railitem"></span>
                <span class="ptlb-mock__railitem"></span>
              </div>
              <div class="ptlb-mock__main">
                <div class="ptlb-mock__card">
                  <div class="ptlb-mock__line" style="width:38%;"></div>
                  <div class="ptlb-mock__line" style="width:92%;"></div>
                  <div class="ptlb-mock__line" style="width:78%; margin-bottom:0;"></div>
                </div>
                <div class="ptlb-mock__card">
                  <div class="ptla-shot__bars" style="height:70px;">
                    <i style="height:44%;"></i>
                    <i style="height:70%;"></i>
                    <i style="height:52%;"></i>
                    <i style="height:90%;"></i>
                    <i style="height:60%;"></i>
                    <i style="height:36%;"></i>
                    <i style="height:66%;"></i>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section class="ptlb-strip">
          <div class="ptlb-stat">
            <b>Telegram</b>
            <span>Sin app propia, sin contraseñas para el paciente.</span>
          </div>
          <div class="ptlb-stat">
            <b>Local</b>
            <span>El análisis de sentimiento corre en tu servidor.</span>
          </div>
          <div class="ptlb-stat">
            <b>Por paciente</b>
            <span>Una clave de cifrado distinta para cada historia.</span>
          </div>
        </section>

        <footer style="padding:24px 0 32px; font-size:13px; color:#667085; border-top:1px solid #e4e7ec;">
          Alethea — Centro de Control Clínico
        </footer>
      </div>
    </div>
    """
  end

  # ── Variant C — Single screen ─────────────────────────────────────

  def variant_c(assigns) do
    ~H"""
    <div class="ptl ptlc">
      <div class="ptl-shell">
        <nav class="ptl-nav">
          <.link navigate={~p"/"} class="ptl-brand">
            <span class="ptl-brand__mark">
              <img src={~p"/images/logo.svg"} alt="" width="16" />
            </span>
            Alethea
          </.link>
          <div class="ptl-navlinks">
            <.link navigate={~p"/login"} class="ptl-link">Iniciar sesión</.link>
            <.link navigate={~p"/register"} class="ptl-cta ptl-cta--light ptl-cta--sm">
              Crear cuenta
            </.link>
          </div>
        </nav>
      </div>

      <main class="ptlc-main">
        <div class="ptl-shell">
          <h1 class="ptlc-title">La semana de tu paciente, resumida antes de la sesión.</h1>
          <p class="ptlc-lede">
            Alethea convierte el registro diario en Telegram en una historia clínica
            estructurada y cifrada. Vos leés el resumen; el contenido crudo queda cerrado.
          </p>

          <div class="ptlc-steps">
            <div class="ptlc-step">
              <span class="ptlc-step__n">Paso 01</span>
              <b>Invitás por Telegram</b>
              <span>Un enlace desde el panel. El paciente no crea cuenta.</span>
            </div>
            <div class="ptlc-step">
              <span class="ptlc-step__n">Paso 02</span>
              <b>Escribe cuando lo necesita</b>
              <span>La IA acompaña con tono clínicamente neutro.</span>
            </div>
            <div class="ptlc-step">
              <span class="ptlc-step__n">Paso 03</span>
              <b>Leés el resumen semanal</b>
              <span>Métricas, evolución y alertas de riesgo.</span>
            </div>
          </div>

          <.link navigate={~p"/register"} class="ptl-cta ptl-cta--light">Crear cuenta</.link>
        </div>
      </main>

      <div class="ptl-shell">
        <footer class="ptlc-foot">
          Alethea — Centro de Control Clínico · Cifrado por paciente
        </footer>
      </div>
    </div>
    """
  end
end
