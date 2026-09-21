defmodule AletheaWeb.GroundedChat.HypothesisPanel do
  @moduledoc """
  Panel *Hipótesis para revisar* del chat de consulta clínica
  fundamentada (issue #231, ADR-010).

  Componente independiente de `AletheaWeb.ConsultationLive` (#227):
  se construye y testea sin esperar a que exista esa carcasa.
  Renderiza la `Hypothesis.t()` que produce
  `Alethea.ClinicalRecord.Rag.Consultation.HypothesisPolicy.evaluate/2`
  (#229) — nunca decide si aplica ni construye evidencia, solo
  muestra lo que ya fue autorizado y construido server-side.

  Invariantes de ADR-010 que este componente garantiza:

    * Nunca se renderiza cuando no hay hipótesis para este turno
      (`hypothesis: nil` ⇒ el `<section>` no existe en el HTML, no
      solo oculto por CSS).
    * El disclaimer clínico precede, en el HTML, a la afirmación. Se
      lee de `@hypothesis.disclaimer` — el panel confía en el campo
      que ya viene con el struct (`@enforce_keys`, seteado siempre por
      `Hypothesis.disclaimer/0` dentro de `evaluate/2`), nunca lo
      recalcula ni lo redacta por su cuenta.
    * La evidencia se cita con
      `AletheaWeb.CoreComponents.citation_list/1` — el mismo renderer
      que usa *Síntesis* (#234) — sin markup propio, tal como exige
      el hand-off documentado en `Alethea.ClinicalRecord.Rag.Citation`.

  ## Adaptación al contrato real de #229 (2026-09-17)

  Hasta que #229 aterrizara en la rama base, este panel definía su
  propia interfaz provisional (`Claim.t()`, `claims: [Claim.t()]`,
  citas vía `Alethea.ClinicalRecord.Rag.Citation` construidas a mano
  en los tests). Con `HypothesisPolicy` ya mergeado, el panel se
  adaptó al contrato real en vez de al revés:

    * `hypothesis: Hypothesis.t() | nil` (singular — `evaluate/2`
      produce como máximo una hipótesis por turno) reemplaza
      `claims: [Claim.t()]`.
    * `Hypothesis.sources` trae `[Alethea.ClinicalRecord.Rag.
      Consultation.Source.t()]` (#226a), no `[Citation.t()]` (#230).
      `citation_list/1` exige `%Citation{}` exactamente (pattern
      match de struct) y `Source.t()` no tiene `source_ref` — esa
      conversión ahora vive en `AletheaWeb.GroundedChat.SourceCitation`
      (promovida en #235c, ver "Hand-off" abajo — este panel solo
      delega).
    * El disclaimer ya no es un borrador propio: es
      `Hypothesis.disclaimer/0`, texto server-owned y verbatim.

  ## Hand-off

    * #229 (`HypothesisPolicy.evaluate/2`) decide si hay hipótesis
      para este turno y construye `Hypothesis.t()` — este panel
      nunca lo hace.
    * #227 monta este componente dentro de `ConsultationLive`.
    * #235b lo compone junto al panel *Síntesis*: prueba la
      separación visible exigida por ADR-010 (cerrado).
    * #235c promueve `source_to_citation/1` (antes privada acá) a
      `AletheaWeb.GroundedChat.SourceCitation`, pública, para que
      *Síntesis* la reuse al unificar su propio listado de fuentes con
      `citation_list/1` (cerrado — este panel ahora solo delega).
  """
  use AletheaWeb, :html

  alias Alethea.ClinicalRecord.Rag.Consultation.Hypothesis
  alias AletheaWeb.GroundedChat.SourceCitation

  attr :id, :string, required: true, doc: "id único del panel (por turno de conversación)"

  attr :hypothesis, :any,
    default: nil,
    doc:
      "la %Hypothesis{} que produjo HypothesisPolicy.evaluate/2, o nil si no aplica a este turno"

  def hypothesis_panel(assigns) do
    assigns = assign(assigns, :citations, citations_for(assigns[:hypothesis]))

    ~H"""
    <section
      :if={@hypothesis}
      id={@id}
      class="review-hypothesis-panel"
      aria-labelledby={"#{@id}-title"}
    >
      <p class="pt-eyebrow">C1 autorizado · lectura interpretativa</p>

      <h2 id={"#{@id}-title"}>Hipótesis para revisar</h2>

      <div id={"#{@id}-disclaimer"} class="review-hypothesis-panel__disclaimer">
        <strong>Disclaimer clínico</strong>
        <p>{@hypothesis.disclaimer}</p>
      </div>

      <p class="review-hypothesis-panel__statement">{@hypothesis.statement}</p>
      <.citation_list citations={@citations} />
    </section>
    """
  end

  defp citations_for(nil), do: []

  defp citations_for(%Hypothesis{sources: sources}) do
    Enum.map(sources, &SourceCitation.source_to_citation/1)
  end
end
