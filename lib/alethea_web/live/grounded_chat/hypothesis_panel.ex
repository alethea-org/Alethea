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
      match de struct) y `Source.t()` no tiene `source_ref` —
      `source_to_citation/1` abajo hace esa conversión, pura, sin
      tocar `citation.ex` ni `core_components.ex` (de #230).
    * El disclaimer ya no es un borrador propio: es
      `Hypothesis.disclaimer/0`, texto server-owned y verbatim.

  ## Hand-off

    * #229 (`HypothesisPolicy.evaluate/2`) decide si hay hipótesis
      para este turno y construye `Hypothesis.t()` — este panel
      nunca lo hace.
    * #227 monta este componente dentro de `ConsultationLive`.
    * #235 lo compone junto al panel *Síntesis*: prueba la
      separación visible exigida por ADR-010.
  """
  use AletheaWeb, :html

  alias Alethea.ClinicalRecord.Rag.Citation
  alias Alethea.ClinicalRecord.Rag.Consultation.{Hypothesis, Source}

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
    Enum.map(sources, &source_to_citation/1)
  end

  # Adapta un Source.t() (#226a) a un Citation.t() (#230) para que
  # citation_list/1 pueda renderizarlo — esa función exige %Citation{}
  # exactamente (pattern match de struct en citation/1) y Source.t()
  # no tiene source_ref.
  #
  # No usa Citation.from_retrieval_result/1 ("the only constructor" en
  # citation.ex) porque ese constructor espera el mapa crudo del
  # retrieval envelope, no un %Source{} ya construido; construye el
  # struct directamente en su lugar. Única forma de adaptar sin tocar
  # citation.ex.
  #
  # Rechaza excerpt vacío igual que from_retrieval_result/1: ni
  # HypothesisPolicy.evaluate/2 ni Source.from_results/1 garantizan
  # excerpt no vacío por elemento (evaluate/2 solo rechaza
  # results == [], no valida cada resultado individual) — esta es la
  # única garantía real de "no citar una fuente sin contenido
  # verificable" en esta cadena.
  #
  # score y chunk_index quedan en nil — Source.t() no los tiene y
  # citation/1 nunca los renderiza.
  #
  # Privado por ahora: si #235 termina necesitando la misma conversión
  # al unificar con Síntesis, promoverlo a público ahí, no antes.
  @spec source_to_citation(Source.t()) :: Citation.t()
  defp source_to_citation(%Source{} = source) do
    if source.excerpt == "" do
      raise ArgumentError, "Source has empty excerpt — empty cite cannot be verified"
    end

    short_chunk_id =
      source.reference.chunk_id
      |> to_string()
      |> String.slice(0, 8)

    %Citation{
      source_ref: "#{source.reference.resource_type}/#{short_chunk_id}",
      kind: source.kind,
      occurred_at: source.occurred_at,
      excerpt: source.excerpt,
      score: nil,
      chunk_index: nil
    }
  end
end
