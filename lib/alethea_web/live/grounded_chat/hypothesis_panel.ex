defmodule AletheaWeb.GroundedChat.HypothesisPanel do
  @moduledoc """
  Panel *Hipótesis para revisar* del chat de consulta clínica
  fundamentada (issue #231, ADR-010).

  Componente independiente de `AletheaWeb.ConsultationLive` (#227):
  se construye y testea sin esperar a que exista esa carcasa. Quien
  la monte (#227/#235) decide `interpretive?` vía la política C1
  (#229, todavía no implementada) y arma la lista de `Claim.t()` a
  partir de citas ya construidas por
  `Alethea.ClinicalRecord.Rag.Citation.from_retrieval_result/1`
  (#230) — este módulo nunca construye ni valida una cita, solo la
  renderiza.

  Invariantes de ADR-010 que este componente garantiza:

    * Nunca se renderiza ante una consulta no interpretativa
      (`interpretive?: false` ⇒ el `<section>` no existe en el HTML,
      no solo oculto por CSS).
    * El disclaimer clínico precede, en el HTML, a toda afirmación.
    * Cada afirmación se cita con `AletheaWeb.CoreComponents.citation_list/1`
      — el mismo renderer que usa *Síntesis* (#234) — sin markup
      propio, tal como exige el hand-off documentado en
      `Alethea.ClinicalRecord.Rag.Citation`.

  ## Estado provisional

    * `Claim.t()` y el atributo `interpretive?` son una interfaz
      **provisional**: su forma la define este cambio, no la política
      C1 (#229), que todavía no existe -- es renegociable cuando esa
      política aterrice.
    * El texto del disclaimer es un **borrador** de ingeniería,
      pendiente de revisión clínica/legal antes de exponerse a
      producción (PD4).

  ## Hand-off

    * #229 (política C1) decide `interpretive?` y arma la lista de
      `Claim.t()` a partir de citas ya construidas por #230.
    * #227 monta este componente dentro de `ConsultationLive`.
    * #235 lo compone junto al panel *Síntesis*: prueba la separación
      visible (ADR-010, PD2) y **debe tratar un desacalce entre la
      forma de `Claim.t()` y el retorno real de #229 como un punto de
      decisión explícito, nunca adaptarlo en silencio**.
  """
  use AletheaWeb, :html

  defmodule Claim do
    @moduledoc """
    Una afirmación interpretativa de la hipótesis, junto con la
    evidencia server-derived que la sostiene. La política C1 (#229)
    es la única responsable de construir esta lista; el panel solo
    renderiza lo que recibe.

    **PD1:** esta forma se autoría aquí, no se negoció con #229 --
    es renegociable cuando esa política aterrice.
    """

    alias Alethea.ClinicalRecord.Rag.Citation

    @type t :: %__MODULE__{
            id: String.t(),
            statement: String.t(),
            citations: [Citation.t()]
          }

    @enforce_keys [:id, :statement, :citations]
    defstruct [:id, :statement, :citations]

    @doc """
    Constructor validado para `%Claim{}`. Preferido sobre el literal
    de struct: valida en construcción en vez de fallar de forma opaca
    en render. Los literales `%Claim{}` siguen siendo válidos (PD1 --
    endurecer esto en un tipo opaco congelaría una interfaz que #229
    todavía puede renegociar).

    Debe permanecer puro (sin `DateTime.utc_now()` ni similares) para
    poder usarse en fixtures de test definidos como atributos de
    módulo (tiempo de compilación).
    """
    @spec build(String.t(), String.t(), [Citation.t()]) :: t()
    def build(id, statement, citations)
        when is_binary(id) and id != "" and is_binary(statement) and statement != "" and
               is_list(citations) do
      unless Enum.all?(citations, &match?(%Citation{}, &1)) do
        raise ArgumentError, "citations must be a list of %Citation{} structs"
      end

      %__MODULE__{id: id, statement: statement, citations: citations}
    end

    def build(id, statement, citations) do
      raise ArgumentError,
            "invalid Claim.build/3 arguments: id=#{inspect(id)}, statement=#{inspect(statement)}, citations=#{inspect(citations)}"
    end
  end

  attr :id, :string, required: true, doc: "id único del panel (por turno de conversación)"

  attr :interpretive?, :boolean,
    required: true,
    doc: "true cuando la política C1 (#229) autoriza lectura interpretativa"

  attr :claims, :list, default: [], doc: "lista de %Claim{} ya autorizados por #229"

  def hypothesis_panel(assigns) do
    ~H"""
    <section
      :if={@interpretive?}
      id={@id}
      class="review-hypothesis-panel"
      aria-labelledby={"#{@id}-title"}
    >
      <p class="pt-eyebrow">C1 autorizado · lectura interpretativa</p>
      <h2 id={"#{@id}-title"}>Hipótesis para revisar</h2>
      <%!-- PD4: borrador de ingeniería, pendiente de revisión clínica/legal --%>
      <div id={"#{@id}-disclaimer"} class="review-hypothesis-panel__disclaimer">
        <strong>Disclaimer clínico</strong>
        <p>
          Esta hipótesis es revisable por el profesional. No es un diagnóstico ni una recomendación terapéutica.
        </p>
      </div>
      <ul class="review-hypothesis-panel__claims">
        <li :for={claim <- @claims} id={claim.id}>
          <p class="review-hypothesis-claim__statement">{claim.statement}</p>
          <.citation_list citations={claim.citations} />
        </li>
      </ul>
    </section>
    """
  end
end
