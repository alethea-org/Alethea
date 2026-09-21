defmodule Alethea.ClinicalRecord.Rag.Consultation.Fake do
  @moduledoc """
  Deterministic `Rag.Consultation` implementation for `:test`/`:dev`.
  Produces any of the four `Answer` outcomes (or `{:error,
  :unauthorized}`) with no real retrieval and no LLM. The outcome is
  chosen by `opts[:outcome]`, falling back to
  `config :alethea, :consultation_fake_outcome` (default `:synthesis`).
  `:synthesis` returns contract-valid sources built from a fixed
  fixture through `Source.from_results/1`.
  """

  @behaviour Alethea.ClinicalRecord.Rag.Consultation

  alias Alethea.ClinicalRecord.Rag.Consultation.{Answer, Source}

  @default_pending 2

  @impl true
  def answer(_professional, _patient_id, _query, opts) do
    case selected_outcome(opts) do
      :unauthorized ->
        {:error, :unauthorized}

      :synthesis ->
        {:ok,
         %Answer{
           outcome: :synthesis,
           synthesis: canned_synthesis(),
           sources: canned_sources(),
           hypothesis: selected_hypothesis(opts)
         }}

      :no_evidence ->
        {:ok, %Answer{outcome: :no_evidence, synthesis: nil, sources: []}}

      :stale ->
        {:ok, %Answer{outcome: :stale, synthesis: nil, sources: [], pending: pending_count(opts)}}

      :provider_failure ->
        {:ok, %Answer{outcome: :provider_failure, synthesis: nil, sources: []}}
    end
  end

  @impl true
  def open(_professional, _patient_id) do
    case selected_outcome([]) do
      :unauthorized -> {:error, :unauthorized}
      _other -> {:ok, %{chunk_count: 3, freshness: %{stale?: false, pending: 0}}}
    end
  end

  defp selected_outcome(opts) do
    Keyword.get(opts, :outcome) ||
      Application.get_env(:alethea, :consultation_fake_outcome, :synthesis)
  end

  # #235b/AD2 — pass-through only, never constructed here. A fake that
  # called `HypothesisPolicy.evaluate/2` would be a second AST-scan call
  # site (R9/R11) and would force an allowlist that hollows out the
  # Hypothesis Wiring Gate's invariant. The real `%Hypothesis{}` is built
  # in test-support (`Alethea.RagFixtures.canned_hypothesis!/0`) through
  # the real policy, never hand-rolled.
  defp selected_hypothesis(opts),
    do:
      Keyword.get(opts, :hypothesis) ||
        Application.get_env(:alethea, :consultation_fake_hypothesis)

  defp pending_count(opts),
    do:
      Keyword.get(opts, :pending) ||
        Application.get_env(:alethea, :consultation_fake_pending, @default_pending)

  defp canned_synthesis,
    do:
      "Según los fragmentos citados, el paciente reporta una mejoría sostenida del ánimo en la última semana."

  defp canned_sources, do: Source.from_results(canned_results())

  @doc """
  The fixed retrieval-result fixture behind `:synthesis`'s `sources`.
  Public and reused by `Alethea.RagFixtures.canned_hypothesis!/0`
  (#235b/AD2) so the fake's sources and the fixture's hypothesis cite
  the exact same fragment.
  """
  @spec canned_results() :: [map()]
  def canned_results do
    [
      %{
        chunk_id: "11111111-1111-1111-1111-111111111111",
        source_resource_type: "clinical_note",
        source_resource_id: "22222222-2222-2222-2222-222222222222",
        source_occurred_at: ~U[2026-01-15 10:00:00.000000Z],
        target_behavior_id: nil,
        content: "El paciente reporta mejoría del ánimo esta semana y mayor actividad social."
      }
    ]
  end
end
