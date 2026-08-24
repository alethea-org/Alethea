defmodule AletheaWeb.ClinicalReviewPrototypeLive do
  @moduledoc """
  PROTOTYPE ONLY — four clinician-review layouts for Wayfinder ticket #186.

  Question: Which interaction makes provisional functional-analysis drafts,
  immutable citations, contradictions, RAG freshness, and clinician-authored
  summaries safe and understandable to review?

  Four variants on `/prototype/clinical-review?variant=review|timeline|matrix|hybrid`.
  All data and summary state are in memory; this module never reads or writes
  clinical records.
  """
  use AletheaWeb, :live_view

  @variants [
    {"review", "A — Mesa de revisión"},
    {"timeline", "B — Línea de tiempo de la evidencia"},
    {"matrix", "C — Matriz de contradicciones"},
    {"hybrid", "D — Revisión híbrida"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Prototipo de revisión clínica")
     |> assign(:summary_form, to_form(%{"text" => ""}, as: :summary))
     |> assign(:draft_summary, nil)
     |> assign(:compare_contradiction?, false)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, assign(socket, :variant, variant_from_params(params))}
  end

  @impl true
  def handle_event("cycle_variant", %{"direction" => direction}, socket) do
    {:noreply,
     push_patch(socket, to: prototype_path(next_variant(socket.assigns.variant, direction)))}
  end

  def handle_event("save_summary_in_memory", %{"summary" => %{"text" => text}}, socket) do
    {:noreply,
     socket
     |> assign(:draft_summary, String.trim(text))
     |> assign(:summary_form, to_form(%{"text" => text}, as: :summary))}
  end

  def handle_event("toggle_contradiction_comparison", _params, socket) do
    {:noreply, update(socket, :compare_contradiction?, &(!&1))}
  end

  defp variant_from_params(%{"variant" => variant})
       when variant in ["review", "timeline", "matrix", "hybrid"],
       do: variant

  defp variant_from_params(_), do: "review"

  defp next_variant(current, "previous") do
    current
    |> variant_index()
    |> Kernel.-(1)
    |> rem(length(@variants))
    |> then(fn index -> if index < 0, do: length(@variants) - 1, else: index end)
    |> variant_key()
  end

  defp next_variant(current, _direction) do
    current
    |> variant_index()
    |> Kernel.+(1)
    |> rem(length(@variants))
    |> variant_key()
  end

  defp variant_index(key), do: Enum.find_index(@variants, fn {variant, _} -> variant == key end)
  defp variant_key(index), do: @variants |> Enum.at(index) |> elem(0)

  defp variant_label(key),
    do: @variants |> Enum.find(fn {variant, _} -> variant == key end) |> elem(1)

  defp prototype_path(variant), do: ~p"/prototype/clinical-review?variant=#{variant}"

  defp source_note(assigns) do
    ~H"""
    <article class="crp-source" id={@id}>
      <div class="crp-source__meta"><span>Nota clínica inmutable</span><time>{@date}</time></div>
      <p>{@body}</p>
      <a href={"##{@excerpt_id}"}>Ver extracto citado inmutable ↓</a>
    </article>
    """
  end

  defp citation(assigns) do
    ~H"""
    <article class="crp-citation" id={@id}>
      <p class="crp-citation__label">Extracto citado · Inmutable y atribuible</p>
      <blockquote>“{@quote}”</blockquote>
      <p><a href={"##{@source_id}"}>Nota clínica de origen {@source_label}</a> · {@origin}</p>
    </article>
    """
  end

  defp safety_header(assigns) do
    ~H"""
    <header class="crp-header">
      <div>
        <p class="crp-kicker">PROTOTIPO · Datos representativos en memoria · Wayfinder #186</p>
        <h1>Revisión del análisis funcional</h1>
        <p>
          Historia Clínica propiedad del paciente · Acceso autorizado por el Profesional Responsable
        </p>
      </div>
      <div class="crp-statuses" aria-label="Estado de la revisión">
        <span class="crp-badge crp-badge--draft">Borrador provisional · no es un diagnóstico</span>
        <span class="crp-badge crp-badge--pending">
          Proyección RAG pendiente · no es una fuente autorizada
        </span>
      </div>
    </header>
    """
  end

  defp summary_editor(assigns) do
    ~H"""
    <section class="crp-summary" aria-labelledby="clinician-summary-title">
      <div>
        <p class="crp-kicker">Redactado por el profesional clínico</p>
        <h2 id="clinician-summary-title">Resumen de la revisión</h2>
        <p>
          Solo el Profesional Responsable puede redactar una conclusión clínica. Este prototipo conserva el texto en memoria y no crea una entrada en la Historia Clínica.
        </p>
      </div>
      <.form for={@summary_form} id="clinician-summary-form" phx-submit="save_summary_in_memory">
        <.input
          field={@summary_form[:text]}
          type="textarea"
          label="Resumen de revisión clínica"
          placeholder="Registre su interpretación, incertidumbre o pregunta de seguimiento…"
          rows="4"
        />
        <button id="save-summary-in-memory" type="submit">
          Conservar el borrador en este prototipo
        </button>
      </.form>
      <p :if={@draft_summary not in [nil, ""]} id="in-memory-summary" class="crp-memory-note">
        Borrador clínico en memoria: {@draft_summary}
      </p>
    </section>
    """
  end

  defp review_bench(assigns) do
    ~H"""
    <section class="crp-review-bench" aria-label="Diseño de mesa de revisión">
      <aside class="crp-column">
        <h2>Rastreo de fuentes</h2>
        <.source_note
          id="source-note-1"
          date="Nota clínica · 12 jun"
          excerpt_id="excerpt-1"
          body="El informe escolar registró evitación antes de la presentación y una solicitud posterior para salir del aula."
        />
        <.source_note
          id="source-note-2"
          date="Nota clínica · 19 jun"
          excerpt_id="excerpt-2"
          body="El paciente describió haber permanecido en el grupo pese a la aprensión durante una actividad comparable."
        />
      </aside>
      <main class="crp-draft-sheet">
        <p class="crp-kicker">Borrador provisional de análisis funcional</p>
        <h2>Situación → respuesta → consecuencia</h2>
        <ol class="crp-chain">
          <li><strong>Situación</strong><span>Presentación pública anticipada</span></li>
          <li>
            <strong>Respuesta observada</strong><span>Evitación registrada en una fuente; participación en otra</span>
          </li>
          <li>
            <strong>Posible consecuencia</strong><span>La reducción a corto plazo de la exposición sigue siendo una hipótesis, no una conclusión</span>
          </li>
        </ol>
        <div class="crp-warning">
          <strong>Contradicción no resuelta</strong>
          <p>
            Dos fuentes inmutables describen respuestas diferentes ante situaciones comparables. No las reduzca a una única decisión clínica.
          </p>
        </div>
        <div class="crp-citations">
          <.citation
            id="excerpt-1"
            source_id="source-note-1"
            source_label="12 jun"
            origin="Informe escolar, párrafo 3"
            quote="solicitó salir del aula antes de presentar"
          /><.citation
            id="excerpt-2"
            source_id="source-note-2"
            source_label="19 jun"
            origin="Observación de consulta, párrafo 2"
            quote="permaneció en el grupo pese a la aprensión"
          />
        </div>
      </main>
      <aside class="crp-column crp-column--action">
        <h2>Criterios de revisión</h2>
        <p class="crp-gate">1 contradicción no resuelta</p>
        <p class="crp-gate">1 elemento elegible aún en indexación</p>
        <p class="crp-gate">No se generó ninguna recomendación</p>
        <.summary_editor summary_form={@summary_form} draft_summary={@draft_summary} />
      </aside>
    </section>
    """
  end

  defp evidence_timeline(assigns) do
    ~H"""
    <section class="crp-timeline-layout" aria-label="Diseño de línea de tiempo de la evidencia">
      <main>
        <p class="crp-kicker">Evidencia cronológica antes de la interpretación</p>
        <h2>Contenido de la Historia Clínica</h2>
        <div class="crp-timeline">
          <div>
            <time>12 jun</time>
            <.source_note
              id="timeline-source-1"
              date="Nota clínica inmutable"
              excerpt_id="timeline-excerpt-1"
              body="Informe escolar: evitación previa a la presentación."
            /><.citation
              id="timeline-excerpt-1"
              source_id="timeline-source-1"
              source_label="12 jun"
              origin="Informe escolar, párrafo 3"
              quote="solicitó salir del aula antes de presentar"
            />
          </div>
          <div>
            <time>19 jun</time>
            <.source_note
              id="timeline-source-2"
              date="Nota clínica inmutable"
              excerpt_id="timeline-excerpt-2"
              body="Observación de consulta: participación pese a la aprensión."
            /><.citation
              id="timeline-excerpt-2"
              source_id="timeline-source-2"
              source_label="19 jun"
              origin="Observación de consulta, párrafo 2"
              quote="permaneció en el grupo pese a la aprensión"
            />
          </div>
          <div class="crp-timeline__pending">
            <time>Pendiente</time><strong>Proyección RAG</strong>
            <p>
              La Evidencia Clínica elegible está en cola para indexación. La recuperación puede ser incompleta; la Historia Clínica sigue siendo la fuente autorizada.
            </p>
          </div>
        </div>
      </main>
      <aside class="crp-interpretation">
        <p class="crp-kicker">Panel de revisión</p>
        <h2>Interpretación provisional</h2>
        <p>
          Las diferentes respuestas pueden reflejar variaciones contextuales. El borrador no determina causa, diagnóstico ni tratamiento.
        </p>
        <div class="crp-warning">
          <strong>Deténgase ante la contradicción</strong>
          <p>Compare los dos extractos citados antes de documentar una conclusión.</p>
        </div>
        <.summary_editor summary_form={@summary_form} draft_summary={@draft_summary} />
      </aside>
    </section>
    """
  end

  defp contradiction_matrix(assigns) do
    ~H"""
    <section class="crp-matrix-layout" aria-label="Diseño de matriz de contradicciones">
      <div>
        <p class="crp-kicker">Revisión con comparación previa</p>
        <h2>Las afirmaciones de evidencia se mantienen separadas</h2>
        <p class="crp-matrix-intro">
          Una matriz hace visible el desacuerdo antes de que un profesional clínico redacte un resumen.
        </p>
      </div>
      <div class="crp-matrix" role="table" aria-label="Matriz de contradicciones de evidencia">
        <div role="row" class="crp-matrix__head">
          <span role="columnheader">Fuente inmutable</span><span role="columnheader">Respuesta observada</span><span role="columnheader">Relevancia para el borrador</span><span role="columnheader">Estado</span>
        </div>
        <div id="matrix-note-1" role="row">
          <a role="cell" href="#matrix-excerpt-1">Nota clínica · 12 jun</a><span role="cell">Evitación</span><span role="cell">Puede respaldar la hipótesis de escape</span><strong role="cell">Contradice</strong>
        </div>
        <div id="matrix-note-2" role="row">
          <a role="cell" href="#matrix-excerpt-2">Nota clínica · 19 jun</a><span role="cell">Participación pese a la aprensión</span><span role="cell">Puede indicar variación contextual</span><strong role="cell">Contradice</strong>
        </div>
        <div role="row" class="crp-matrix__pending">
          <span role="cell">Proyección RAG</span><span role="cell">No disponible</span><span role="cell">Sin ponderación hasta su actualización</span><strong role="cell">Indexación pendiente</strong>
        </div>
      </div>
      <div class="crp-matrix-excerpts">
        <.citation
          id="matrix-excerpt-1"
          source_id="matrix-note-1"
          source_label="12 jun"
          origin="Informe escolar, párrafo 3"
          quote="solicitó salir del aula antes de presentar"
        /><.citation
          id="matrix-excerpt-2"
          source_id="matrix-note-2"
          source_label="19 jun"
          origin="Observación de consulta, párrafo 2"
          quote="permaneció en el grupo pese a la aprensión"
        />
      </div>
      <.summary_editor summary_form={@summary_form} draft_summary={@draft_summary} />
    </section>
    """
  end

  defp hybrid_review(assigns) do
    ~H"""
    <section class="crp-review-bench" aria-label="Diseño híbrido de revisión clínica">
      <aside class="crp-column" aria-labelledby="hybrid-evidence-title">
        <p class="crp-kicker">Navegación cronológica</p>
        <h2 id="hybrid-evidence-title">Evidencia de la Historia Clínica</h2>
        <div class="crp-timeline">
          <div>
            <time>12 jun</time>
            <.source_note
              id="hybrid-source-1"
              date="Nota clínica inmutable"
              excerpt_id="hybrid-excerpt-1"
              body="Informe escolar: evitación previa a la presentación y solicitud para salir del aula."
            />
          </div>
          <div>
            <time>19 jun</time>
            <.source_note
              id="hybrid-source-2"
              date="Nota clínica inmutable"
              excerpt_id="hybrid-excerpt-2"
              body="Observación de consulta: participación en el grupo pese a la aprensión."
            />
          </div>
          <div class="crp-timeline__pending" id="hybrid-rag-freshness">
            <time>Pendiente</time><strong>Proyección RAG pendiente de actualización</strong>
            <p>
              La recuperación puede ser incompleta. La Historia Clínica inmutable sigue siendo la fuente autorizada.
            </p>
          </div>
        </div>
      </aside>
      <main class="crp-draft-sheet">
        <p class="crp-kicker">Borrador provisional de análisis funcional</p>
        <h2>Situación → respuesta → consecuencia</h2>
        <ol class="crp-chain">
          <li><strong>Situación</strong><span>Presentación pública anticipada</span></li>
          <li>
            <strong>Respuesta observada</strong><span>Evitación registrada en una fuente; participación en otra</span>
          </li>
          <li>
            <strong>Posible consecuencia</strong><span>La reducción a corto plazo de la exposición sigue siendo una hipótesis, no una conclusión</span>
          </li>
        </ol>
        <div class="crp-warning">
          <strong>Contradicción identificada</strong>
          <p>Dos fuentes inmutables describen respuestas diferentes ante situaciones comparables.</p>
          <button
            id="toggle-contradiction-comparison"
            type="button"
            phx-click="toggle_contradiction_comparison"
            aria-expanded={to_string(@compare_contradiction?)}
            aria-controls="hybrid-contradiction-comparison"
          >
            {if @compare_contradiction?,
              do: "Ocultar comparación de fuentes",
              else: "Comparar las fuentes contradictorias"}
          </button>
        </div>
        <section
          :if={@compare_contradiction?}
          id="hybrid-contradiction-comparison"
          class="crp-hybrid-comparison"
          aria-labelledby="hybrid-comparison-title"
        >
          <p class="crp-kicker">Comparación puntual · no es la jerarquía predeterminada</p>
          <h3 id="hybrid-comparison-title">Fuentes contradictorias</h3>
          <div class="crp-matrix" role="table" aria-label="Comparación de fuentes contradictorias">
            <div role="row" class="crp-matrix__head">
              <span role="columnheader">Fuente inmutable</span><span role="columnheader">Respuesta observada</span><span role="columnheader">Estado</span>
            </div>
            <div role="row">
              <a role="cell" href="#hybrid-excerpt-1">Nota clínica · 12 jun</a><span role="cell">Evitación</span><strong role="cell">Contradice</strong>
            </div>
            <div role="row">
              <a role="cell" href="#hybrid-excerpt-2">Nota clínica · 19 jun</a><span role="cell">Participación pese a la aprensión</span><strong role="cell">Contradice</strong>
            </div>
          </div>
        </section>
        <div class="crp-citations">
          <.citation
            id="hybrid-excerpt-1"
            source_id="hybrid-source-1"
            source_label="12 jun"
            origin="Informe escolar, párrafo 3"
            quote="solicitó salir del aula antes de presentar"
          />
          <.citation
            id="hybrid-excerpt-2"
            source_id="hybrid-source-2"
            source_label="19 jun"
            origin="Observación de consulta, párrafo 2"
            quote="permaneció en el grupo pese a la aprensión"
          />
        </div>
      </main>
      <aside class="crp-column crp-column--action">
        <h2>Criterios de revisión</h2>
        <p class="crp-gate">1 contradicción identificada para comparar</p>
        <p class="crp-gate">Proyección RAG pendiente de actualización</p>
        <p class="crp-gate">No es un diagnóstico ni una recomendación</p>
        <.summary_editor summary_form={@summary_form} draft_summary={@draft_summary} />
      </aside>
    </section>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="clinical-review-prototype" class="crp-page" phx-hook=".PrototypeVariantKeyboard">
      <.safety_header />
      <%= case @variant do %>
        <% "timeline" -> %>
          <.evidence_timeline summary_form={@summary_form} draft_summary={@draft_summary} />
        <% "matrix" -> %>
          <.contradiction_matrix summary_form={@summary_form} draft_summary={@draft_summary} />
        <% "hybrid" -> %>
          <.hybrid_review
            summary_form={@summary_form}
            draft_summary={@draft_summary}
            compare_contradiction?={@compare_contradiction?}
          />
        <% _ -> %>
          <.review_bench summary_form={@summary_form} draft_summary={@draft_summary} />
      <% end %>
      <nav class="crp-switcher" aria-label="Selector de diseño del prototipo">
        <button
          type="button"
          phx-click="cycle_variant"
          phx-value-direction="previous"
          aria-label="Diseño anterior"
        >
          <.icon name="hero-chevron-left" class="size-4" />
        </button>
        <span>{variant_label(@variant)}</span><button
          type="button"
          phx-click="cycle_variant"
          phx-value-direction="next"
          aria-label="Diseño siguiente"
        ><.icon name="hero-chevron-right" class="size-4" /></button>
      </nav>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PrototypeVariantKeyboard">
      export default {
        mounted() {
          this.onKeydown = event => {
            if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return
            if (event.target.matches('input, textarea, [contenteditable="true"]')) return
            event.preventDefault()
            this.pushEvent('cycle_variant', {direction: event.key === 'ArrowLeft' ? 'previous' : 'next'})
          }
          window.addEventListener('keydown', this.onKeydown)
        },
        destroyed() { window.removeEventListener('keydown', this.onKeydown) }
      }
    </script>
    <style>
      .crp-page{max-width:1440px;margin:0 auto;padding:32px 32px 104px;color:var(--colors-body)}.crp-header{display:flex;justify-content:space-between;gap:24px;padding-bottom:24px;border-bottom:1px solid var(--colors-hairline)}.crp-header h1,.crp-page h2{color:var(--colors-ink)}.crp-header h1{font-size:32px;margin:6px 0}.crp-kicker,.crp-source__meta,.crp-citation__label{font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--colors-muted)}.crp-statuses{display:flex;align-items:flex-start;flex-wrap:wrap;gap:8px}.crp-badge{font-size:12px;font-weight:600;padding:7px 10px;border-radius:999px}.crp-badge--draft{background:var(--colors-warn-soft);color:var(--colors-body);border:1px solid var(--colors-warn)}.crp-badge--pending{background:var(--colors-surface-soft);border:1px dashed var(--colors-border-strong)}.crp-review-bench{display:grid;grid-template-columns:minmax(190px,.7fr) minmax(360px,1.5fr) minmax(270px,.9fr);gap:20px;margin-top:28px}.crp-column h2{font-size:16px;margin-bottom:12px}.crp-source,.crp-citation,.crp-summary,.crp-interpretation{background:var(--colors-surface-soft);border:1px solid var(--colors-hairline);border-radius:10px;padding:16px;margin-bottom:12px}.crp-source__meta{display:flex;justify-content:space-between;margin-bottom:10px}.crp-source p,.crp-citation blockquote{line-height:1.5;margin-bottom:12px}.crp-source a,.crp-citation a{color:var(--colors-link);font-size:13px}.crp-draft-sheet{border:1px solid var(--colors-hairline);border-top:5px solid var(--colors-warn);padding:28px;background:white}.crp-chain{list-style:none;margin:22px 0}.crp-chain li{display:grid;grid-template-columns:155px 1fr;gap:16px;padding:15px 0;border-top:1px solid var(--colors-hairline)}.crp-warning{border-left:4px solid var(--colors-danger);background:var(--colors-danger-soft);padding:14px;margin:18px 0}.crp-warning p{margin-top:5px;line-height:1.45}.crp-citations{display:grid;grid-template-columns:1fr 1fr;gap:12px}.crp-gate{padding:12px 0;border-bottom:1px solid var(--colors-hairline);font-weight:600}.crp-summary{margin-top:22px}.crp-summary h2{font-size:18px;margin:4px 0}.crp-summary>div>p:not(.crp-kicker){font-size:13px;line-height:1.45;margin-bottom:14px}.crp-summary button{background:var(--colors-primary);color:var(--colors-on-primary);border:0;border-radius:7px;padding:10px 14px;font-weight:700;cursor:pointer}.crp-memory-note{margin-top:12px;padding:10px;background:var(--colors-success-soft);font-size:13px}.crp-timeline-layout{display:grid;grid-template-columns:minmax(0,1.5fr) minmax(320px,.8fr);gap:42px;margin-top:28px}.crp-timeline{margin-top:24px;border-left:2px solid var(--colors-hairline);padding-left:28px}.crp-timeline>div{position:relative;margin-bottom:26px}.crp-timeline>div:before{content:"";position:absolute;width:12px;height:12px;border-radius:50%;background:var(--colors-primary);left:-35px;top:5px}.crp-timeline time{font-weight:700;display:block;margin-bottom:8px}.crp-timeline__pending{padding:16px;background:var(--colors-warn-soft);border:1px dashed var(--colors-warn)}.crp-timeline__pending p{margin-top:6px;line-height:1.45}.crp-interpretation{align-self:start;position:sticky;top:20px;background:white;border-top:5px solid var(--colors-primary)}.crp-matrix-layout{margin-top:28px}.crp-matrix-intro{margin:6px 0 20px}.crp-matrix{border:1px solid var(--colors-hairline);overflow:auto}.crp-matrix [role=row]{display:grid;grid-template-columns:1.1fr 1fr 1.5fr 1fr;min-width:700px}.crp-matrix [role=cell],.crp-matrix [role=columnheader]{padding:15px;border-bottom:1px solid var(--colors-hairline);line-height:1.4}.crp-matrix__head{background:var(--colors-primary);color:var(--colors-on-primary);font-size:12px;text-transform:uppercase;letter-spacing:.06em}.crp-matrix strong{color:var(--colors-danger)}.crp-matrix__pending{background:var(--colors-warn-soft)}.crp-matrix-excerpts{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-top:18px}.crp-switcher{position:fixed;left:50%;bottom:20px;transform:translateX(-50%);z-index:20;display:flex;align-items:center;gap:14px;padding:8px 10px;background:var(--colors-primary);color:var(--colors-on-primary);border-radius:999px;box-shadow:0 8px 24px rgba(0,0,0,.22)}.crp-switcher button{display:grid;place-items:center;width:34px;height:34px;border:0;border-radius:50%;background:var(--colors-surface-strong);color:var(--colors-ink);cursor:pointer}.crp-switcher span{font-size:13px;font-weight:700;min-width:145px;text-align:center}@media(max-width:900px){.crp-header,.crp-review-bench,.crp-timeline-layout{display:block}.crp-header{padding-bottom:18px}.crp-statuses{margin-top:14px}.crp-column,.crp-draft-sheet,.crp-interpretation{margin-top:18px}.crp-citations,.crp-matrix-excerpts{grid-template-columns:1fr}.crp-chain li{grid-template-columns:1fr}.crp-interpretation{position:static}.crp-page{padding:20px 16px 96px}}
    </style>
    """
  end
end
