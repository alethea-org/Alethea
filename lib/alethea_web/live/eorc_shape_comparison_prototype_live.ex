defmodule AletheaWeb.EorcShapeComparisonPrototypeLive do
  @moduledoc """
  PROTOTYPE ONLY — side-by-side comparison of flat vs expanded E-O-R-C
  draft shape. Wayfinder #201 ticket #202.

  Question: Which draft shape helps a licensed clinician complete a
  functional behavior analysis faster and more completely on the same
  representative clinical material: the current flat
  "Situación → respuesta → consecuencia" chain, or an expanded E-O-R-C
  structure with sub-sections — E differentiated into distal and
  immediate antecedents, R split into physiological / cognitive / motor
  response channels, O as organism variables, and C split into
  short-term and long-term consequences?

  All data and gap annotations are in-memory synthetic material;
  this module never reads or writes clinical records.
  """

  use AletheaWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Comparación E-O-R-C · prototipo")
     |> assign(:show_gap_panel, true)}
  end

  @impl true
  def handle_event("toggle_gap_panel", _params, socket) do
    {:noreply, update(socket, :show_gap_panel, &(!&1))}
  end

  defp safety_header(assigns) do
    ~H"""
    <header class="esc-header">
      <div>
        <p class="esc-kicker">
          PROTOTIPO · Datos representativos en memoria · Wayfinder #201 · Ticket #202
        </p>
        <h1>Comparación de forma del borrador E-O-R-C</h1>
        <p>
          Historia Clínica propiedad del paciente · Acceso autorizado por el Profesional Responsable
        </p>
      </div>
      <div class="esc-statuses" aria-label="Estado del prototipo">
        <span class="esc-badge esc-badge--draft">
          Borrador provisional · no es un diagnóstico
        </span>
        <span class="esc-badge esc-badge--pending">
          Proyección RAG pendiente · no es una fuente autorizada
        </span>
      </div>
    </header>
    """
  end

  defp shared_sources(assigns) do
    ~H"""
    <section class="esc-sources" aria-label="Notas clínicas de origen compartidas">
      <h2>Notas clínicas inmutables (compartidas por ambas formas)</h2>
      <div class="esc-sources__grid">
        <article id="esc-source-1" class="esc-source">
          <div class="esc-source__meta">
            <span>Nota clínica inmutable</span><time>12 jun</time>
          </div>
          <p>
            El informe escolar registró evitación antes de la presentación y
            una solicitud posterior para salir del aula.
          </p>
          <a href="#esc-excerpt-1">Ver extracto citado inmutable ↓</a>
        </article>
        <article id="esc-source-2" class="esc-source">
          <div class="esc-source__meta">
            <span>Nota clínica inmutable</span><time>19 jun</time>
          </div>
          <p>
            El paciente describió haber permanecido en el grupo pese a la
            aprensión durante una actividad comparable.
          </p>
          <a href="#esc-excerpt-2">Ver extracto citado inmutable ↓</a>
        </article>
      </div>
    </section>
    """
  end

  defp flat_draft(assigns) do
    ~H"""
    <section class="esc-draft esc-draft--flat" aria-labelledby="flat-title">
      <p class="esc-kicker">Forma A · Cadena plana</p>
      <h2 id="flat-title">Situación → respuesta → consecuencia</h2>
      <p class="esc-draft__sub">
        Estructura actual: tres nodos, sin sub-secciones.
      </p>
      <ol class="esc-chain">
        <li>
          <strong>Situación</strong>
          <span>Presentación pública anticipada</span>
        </li>
        <li>
          <strong>Respuesta observada</strong>
          <span>
            Evitación registrada en una fuente; participación en otra
          </span>
        </li>
        <li>
          <strong>Posible consecuencia</strong>
          <span>
            La reducción a corto plazo de la exposición sigue siendo una
            hipótesis, no una conclusión
          </span>
        </li>
      </ol>
      <div class="esc-warning">
        <strong>Contradicción no resuelta</strong>
        <p>
          Dos fuentes inmutables describen respuestas diferentes ante
          situaciones comparables. No las reduzca a una única decisión clínica.
        </p>
      </div>
    </section>
    """
  end

  defp expanded_draft(assigns) do
    ~H"""
    <section class="esc-draft esc-draft--expanded" aria-labelledby="expanded-title">
      <p class="esc-kicker">Forma B · E-O-R-C expandido</p>
      <h2 id="expanded-title">E · O · R · C con sub-secciones</h2>
      <p class="esc-draft__sub">
        Estructura propuesta: cada componente diferenciado en sub-canales
        confirmables por separado.
      </p>

      <article class="esc-section">
        <header>
          <h3>E · Antecedentes</h3>
        </header>
        <ol class="esc-subchain">
          <li>
            <strong>Distal</strong>
            <span>
              Historia escolar repetida de presentaciones orales con
              respuesta de evitación documentada en informe 12 jun.
            </span>
          </li>
          <li>
            <strong>Inmediato</strong>
            <span>
              Aviso de evaluación oral el día previo (implícito en el
              informe; no hay nota clínica específica que lo registre).
            </span>
          </li>
        </ol>
      </article>

      <article class="esc-section">
        <header>
          <h3>O · Variables del organismo</h3>
        </header>
        <ol class="esc-subchain">
          <li>
            <strong>Sueño</strong>
            <span class="esc-gap">Información no presente en las notas actuales.</span>
          </li>
          <li>
            <strong>Dolor o malestar</strong>
            <span class="esc-gap">Información no presente en las notas actuales.</span>
          </li>
          <li>
            <strong>Hambre o alimentación</strong>
            <span class="esc-gap">Información no presente en las notas actuales.</span>
          </li>
          <li>
            <strong>Historia de aprendizaje</strong>
            <span>
              Múltiples instancias previas con patrón de evitación
              (informe 12 jun).
            </span>
          </li>
        </ol>
      </article>

      <article class="esc-section">
        <header>
          <h3>R · Respuesta</h3>
        </header>
        <ol class="esc-subchain">
          <li>
            <strong>Fisiológica</strong>
            <span class="esc-gap">
              Taquicardia observable — no explicitada en el material
              disponible; inferencia clínica pendiente de corroborar.
            </span>
          </li>
          <li>
            <strong>Cognitiva</strong>
            <span class="esc-gap">
              Verbalización de autoeficacia negativa — no citada
              directamente en el material disponible.
            </span>
          </li>
          <li>
            <strong>Motora</strong>
            <span>
              12 jun: solicitud de salir del aula. 19 jun: permanencia
              en el grupo pese a la aprensión.
            </span>
          </li>
        </ol>
      </article>

      <article class="esc-section">
        <header>
          <h3>C · Consecuencias</h3>
        </header>
        <ol class="esc-subchain">
          <li>
            <strong>Corto plazo</strong>
            <span>
              Salida del aula → eliminación inmediata de la demanda
              aversiva (12 jun).
            </span>
          </li>
          <li>
            <strong>Largo plazo</strong>
            <span class="esc-gap">
              Pérdida de exposición sostenida — formulada como hipótesis,
              no como conclusión; requiere notas adicionales.
            </span>
          </li>
        </ol>
      </article>

      <div class="esc-warning">
        <strong>Contradicción no resuelta</strong>
        <p>
          Dos fuentes inmutables describen respuestas motoras diferentes
          ante situaciones comparables. La estructura expandida las hace
          visibles como sub-canal motor, no como una única respuesta mixta.
        </p>
      </div>
    </section>
    """
  end

  defp shared_citations(assigns) do
    ~H"""
    <section class="esc-citations" aria-label="Extractos citados inmutables compartidos">
      <h2>Extractos citados · Inmutables y atribuibles</h2>
      <div class="esc-citations__grid">
        <article id="esc-excerpt-1" class="esc-citation">
          <p class="esc-citation__label">Extracto citado · Inmutable</p>
          <blockquote>“solicitó salir del aula antes de presentar”</blockquote>
          <p>
            <a href="#esc-source-1">Nota clínica de origen · 12 jun</a> ·
            Informe escolar, párrafo 3
          </p>
        </article>
        <article id="esc-excerpt-2" class="esc-citation">
          <p class="esc-citation__label">Extracto citado · Inmutable</p>
          <blockquote>“permaneció en el grupo pese a la aprensión”</blockquote>
          <p>
            <a href="#esc-source-2">Nota clínica de origen · 19 jun</a> ·
            Observación de consulta, párrafo 2
          </p>
        </article>
      </div>
    </section>
    """
  end

  attr(:show_gap_panel, :boolean, required: true)

  defp gap_panel(assigns) do
    ~H"""
    <section
      :if={@show_gap_panel}
      id="esc-gap-panel"
      class="esc-gap-panel"
      aria-labelledby="gap-panel-title"
    >
      <p class="esc-kicker">Lo que la forma expandida hace visible</p>
      <h2 id="gap-panel-title">Huecos que la cadena plana no expone</h2>
      <p class="esc-gap-panel__intro">
        Estos puntos no aparecen en la forma A y solo emergen cuando cada
        componente se separa en sub-canales confirmables individualmente.
      </p>
      <ul class="esc-gap-list">
        <li>
          <strong>Canal motor vs canal cognitivo vs canal fisiológico</strong>
          <span>
            La cadena plana mezcla las tres respuestas en un único nodo
            "respuesta observada"; la expandida las separa y muestra que
            la fisiológica y la cognitiva no están citadas en el material.
          </span>
        </li>
        <li>
          <strong>Antecedente distal vs inmediato</strong>
          <span>
            La plana colapsa ambos en "situación"; la expandida muestra
            que el antecedente inmediato no tiene nota clínica propia que
            lo registre de manera explícita.
          </span>
        </li>
        <li>
          <strong>Variables del organismo (sueño, dolor, hambre)</strong>
          <span>
            No aparecen en la plana. La expandida las lista explícitamente
            como huecos que la próxima consulta podría cubrir.
          </span>
        </li>
        <li>
          <strong>Consecuencia de corto plazo vs largo plazo</strong>
          <span>
            La plana las mezcla como "una hipótesis"; la expandida las
            separa, dejando el largo plazo explícitamente como hipótesis
            no confirmada.
          </span>
        </li>
      </ul>
      <p class="esc-gap-panel__safety">
        Estos huecos son información clínica faltante, no fallas del
        modelo. La IA no los completa automáticamente; quedan a criterio
        del Profesional Responsable.
      </p>
    </section>
    """
  end

  attr(:show_gap_panel, :boolean, required: true)

  defp criteria_panel(assigns) do
    ~H"""
    <aside class="esc-criteria" aria-label="Criterios de revisión del prototipo">
      <h2>Qué estamos comparando</h2>
      <p class="esc-gate">Mismo material clínico de origen</p>
      <p class="esc-gate">Mismas citas inmutables atribuibles</p>
      <p class="esc-gate">Misma contradicción retenida, no resuelta</p>
      <p class="esc-gate">Sin recomendación ni diagnóstico en ninguna forma</p>
      <p class="esc-gate">Solo el Profesional Responsable confirma o descarta</p>

      <button
        id="toggle-gap-panel"
        type="button"
        phx-click="toggle_gap_panel"
        aria-expanded={to_string(@show_gap_panel)}
        aria-controls="esc-gap-panel"
      >
        {if @show_gap_panel,
          do: "Ocultar panel de huecos",
          else: "Mostrar panel de huecos"}
      </button>

      <h2>Próximo paso</h2>
      <p class="esc-gate esc-gate--next">
        Si la forma B resulta más útil, los tickets #203 (taxonomía de
        cuatro funciones), #204 (detección de puntos ciegos algorítmica)
        y #205 (grafo de mantenimiento no autónomo) parten de los
        sub-canales que aquí se confirman.
      </p>
    </aside>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="eorc-shape-comparison-prototype" class="esc-page">
      <.safety_header />
      <.shared_sources />
      <div class="esc-comparison">
        <.flat_draft />
        <.expanded_draft />
      </div>
      <.shared_citations />
      <div class="esc-footer-grid">
        <.gap_panel show_gap_panel={@show_gap_panel} />
        <.criteria_panel show_gap_panel={@show_gap_panel} />
      </div>
    </div>
    <style>
      .esc-page{max-width:1640px;margin:0 auto;padding:32px 32px 104px;color:var(--colors-body);font-family:inherit}.esc-header{display:flex;justify-content:space-between;gap:24px;padding-bottom:24px;border-bottom:1px solid var(--colors-hairline);flex-wrap:wrap}.esc-header h1{color:var(--colors-ink);font-size:30px;margin:6px 0}.esc-kicker,.esc-source__meta,.esc-citation__label{font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--colors-muted);margin:0 0 8px}.esc-statuses{display:flex;align-items:flex-start;flex-wrap:wrap;gap:8px}.esc-badge{font-size:12px;font-weight:600;padding:7px 10px;border-radius:999px}.esc-badge--draft{background:var(--colors-warn-soft);color:var(--colors-body);border:1px solid var(--colors-warn)}.esc-badge--pending{background:var(--colors-surface-soft);border:1px dashed var(--colors-border-strong)}.esc-sources{margin-top:28px}.esc-sources h2{font-size:16px;margin-bottom:12px}.esc-sources__grid,.esc-citations__grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}.esc-source,.esc-citation{background:var(--colors-surface-soft);border:1px solid var(--colors-hairline);border-radius:10px;padding:16px}.esc-source__meta{display:flex;justify-content:space-between;margin-bottom:10px}.esc-source p,.esc-citation blockquote{line-height:1.5;margin-bottom:12px}.esc-source a,.esc-citation a{color:var(--colors-link);font-size:13px}.esc-comparison{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-top:28px}@media (max-width:1100px){.esc-comparison{grid-template-columns:1fr}}.esc-draft{border:1px solid var(--colors-hairline);border-top:5px solid var(--colors-warn);padding:28px;background:white;height:fit-content}.esc-draft--expanded{border-top-color:var(--colors-link)}.esc-draft h2{color:var(--colors-ink);font-size:20px;margin:0 0 6px}.esc-draft__sub{color:var(--colors-muted);margin:0 0 18px;font-size:13px}.esc-chain,.esc-subchain{list-style:none;margin:14px 0;padding:0}.esc-chain li{display:grid;grid-template-columns:155px 1fr;gap:16px;padding:14px 0;border-top:1px solid var(--colors-hairline)}.esc-subchain li{display:grid;grid-template-columns:140px 1fr;gap:14px;padding:12px 0;border-top:1px solid var(--colors-hairline)}.esc-subchain li:first-child{border-top:0}.esc-section{margin:18px 0;padding:16px;background:var(--colors-surface-soft);border-radius:8px}.esc-section header h3{font-size:14px;margin:0 0 6px;color:var(--colors-ink);letter-spacing:.02em}.esc-gap{color:var(--colors-muted);font-style:italic}.esc-warning{border-left:4px solid var(--colors-danger);background:var(--colors-danger-soft);padding:14px;margin:18px 0}.esc-warning p{margin-top:5px;line-height:1.45}.esc-citations{margin-top:28px}.esc-citations h2{font-size:16px;margin-bottom:12px}.esc-footer-grid{display:grid;grid-template-columns:2fr 1fr;gap:20px;margin-top:28px}@media (max-width:1100px){.esc-footer-grid{grid-template-columns:1fr}}.esc-gap-panel{background:white;border:1px solid var(--colors-hairline);border-radius:10px;padding:24px}.esc-gap-panel__intro{color:var(--colors-muted);margin-bottom:14px}.esc-gap-list{list-style:none;padding:0;margin:0}.esc-gap-list li{padding:12px 0;border-top:1px solid var(--colors-hairline)}.esc-gap-list li:first-child{border-top:0}.esc-gap-list strong{display:block;color:var(--colors-ink);margin-bottom:4px;font-size:14px}.esc-gap-list span{color:var(--colors-body);font-size:13px;line-height:1.5}.esc-gap-panel__safety{margin-top:14px;padding:12px;background:var(--colors-surface-soft);border-radius:6px;font-size:13px;color:var(--colors-muted)}.esc-criteria{background:var(--colors-surface-soft);border:1px solid var(--colors-hairline);border-radius:10px;padding:20px;height:fit-content}.esc-criteria h2{font-size:14px;margin:14px 0 8px}.esc-criteria h2:first-child{margin-top:0}.esc-gate{padding:8px 0;font-size:13px;color:var(--colors-body)}.esc-gate--next{background:white;border:1px dashed var(--colors-border-strong);padding:12px;border-radius:6px;color:var(--colors-muted)}.esc-criteria button{margin-top:14px;padding:10px 12px;background:white;border:1px solid var(--colors-link);color:var(--colors-link);border-radius:6px;cursor:pointer;font-size:13px;font-weight:600}.esc-criteria button:hover{background:var(--colors-surface-soft)}
    </style>
    """
  end
end
