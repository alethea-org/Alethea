defmodule AletheaJobs.AIProposalWorker do
  @moduledoc """
  Clinician-triggered AI functional-analysis pattern generator
  (sdd/alethea/issue-195-clinical-review-workbench, GitHub #195, PR4).

  Enqueued only by `Alethea.ClinicalRecord.request_ai_proposals/3` — the
  sole clinician-triggered entry point into this path (design D2: no
  automatic generation on evidence change). `perform/1` re-authorizes
  the requesting professional against the patient, reads the decrypted
  review timeline, sanitizes every string through `Alethea.AI.Sanitizer`
  before it reaches the chain, and — only on chain success — inserts new
  `Alethea.ClinicalRecord.AIProposal` rows.

  Every inserted row is `status: "pending"`; that status is forced by
  `AIProposal.changeset/2`'s own `put_change/3` (design A6) — this
  worker's insert attrs never carry a `status` key at all, so there is
  no attrs shape this module could construct that would produce
  anything other than "pending".

  This module contains no call into any function of
  `Alethea.ClinicalRecord` that writes a clinical note or advances a
  proposal past "pending" (accept/edit/discard) or writes/replaces the
  functional-analysis draft — verified by a static source scan in
  `AletheaJobs.AIProposalWorkerTest` ("structural safety" describe
  block). A chain failure, an authorization denial, or an encryption
  failure all degrade the same way: broadcast `:ai_proposals_failed` and
  insert nothing — never a partial or fabricated proposal.
  """
  use Oban.Worker, queue: :ai_analysis, max_attempts: 1, unique: [period: 60, fields: [:args]]

  alias Alethea.Accounts
  alias Alethea.Accounts.Professional
  alias Alethea.AI.{LLMConfig, Sanitizer}
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.AIProposal
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo

  require Logger

  @topic_prefix "target_behavior:"

  defp pattern_proposal_chain,
    do:
      Application.get_env(
        :alethea,
        :pattern_proposal_chain,
        Alethea.AI.Chains.PatternProposalChain
      )

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "professional_id" => professional_id,
          "patient_id" => patient_id,
          "target_behavior_id" => target_behavior_id
        }
      }) do
    case Repo.get(Professional, professional_id) do
      nil ->
        Logger.warning("AIProposalWorker: professional not found #{professional_id}")
        broadcast_failed(target_behavior_id, :professional_not_found)
        :ok

      professional ->
        generate(professional, patient_id, target_behavior_id)
    end
  end

  defp generate(professional, patient_id, target_behavior_id) do
    case ClinicalRecord.review_timeline(professional, patient_id, target_behavior_id) do
      {:ok, timeline} ->
        run_chain(professional, patient_id, target_behavior_id, timeline)

      {:error, :unauthorized} ->
        Logger.warning(
          "AIProposalWorker: unauthorized professional=#{professional.id} patient=#{patient_id}"
        )

        broadcast_failed(target_behavior_id, :unauthorized)
        {:error, :unauthorized}

      {:error, reason} ->
        Logger.error("AIProposalWorker: review_timeline failed: #{inspect(reason)}")
        broadcast_failed(target_behavior_id, reason)
        {:error, reason}
    end
  end

  defp run_chain(professional, patient_id, target_behavior_id, timeline) do
    sanitized_evidence =
      timeline
      |> Enum.map(& &1.text)
      |> Enum.map(&Sanitizer.sanitize/1)
      |> Enum.reject(&(&1 == ""))

    case pattern_proposal_chain().run(%{sanitized_evidence: sanitized_evidence}) do
      {:ok, %{proposals: proposals}} when is_list(proposals) ->
        insert_proposals(professional, patient_id, target_behavior_id, proposals)

      {:error, reason} ->
        Logger.error("AIProposalWorker: chain failed: #{inspect(reason)}")
        broadcast_failed(target_behavior_id, reason)
        {:error, reason}
    end
  end

  defp insert_proposals(professional, patient_id, target_behavior_id, proposals) do
    proposals = Enum.reject(proposals, &(&1 in [nil, ""]))

    with patient when not is_nil(patient) <-
           Accounts.get_patient_for_professional(professional.id, patient_id),
         {:ok, kek} <- Accounts.load_professional_kek(professional),
         {:ok, dek} <- Accounts.load_patient_dek(patient, kek) do
      occurred_at = DateTime.utc_now()
      model_version = LLMConfig.get(:pattern_proposal).model

      results =
        Enum.map(proposals, fn text ->
          insert_proposal(
            professional,
            patient,
            dek,
            target_behavior_id,
            text,
            occurred_at,
            model_version
          )
        end)

      if Enum.all?(results, &match?({:ok, _}, &1)) do
        broadcast_ready(target_behavior_id)
        :ok
      else
        Logger.error("AIProposalWorker: one or more proposal inserts failed")
        broadcast_failed(target_behavior_id, :insert_failed)
        {:error, :insert_failed}
      end
    else
      nil ->
        broadcast_failed(target_behavior_id, :unauthorized)
        {:error, :unauthorized}

      {:error, reason} ->
        broadcast_failed(target_behavior_id, reason)
        {:error, reason}
    end
  end

  # Builds and inserts a single new `AIProposal` row. `attrs` never
  # includes a `:status` key — `AIProposal.changeset/2` always forces
  # "pending" itself (design A6). `encrypted_original_text` and
  # `encrypted_text` start identical: this is the model's output at
  # generation time, before any clinician has looked at it.
  defp insert_proposal(
         professional,
         patient,
         dek,
         target_behavior_id,
         text,
         occurred_at,
         model_version
       ) do
    with {:ok, ciphertext} <- PatientVault.encrypt(text, dek) do
      %AIProposal{}
      |> AIProposal.changeset(%{
        encrypted_original_text: ciphertext,
        encrypted_text: ciphertext,
        model_version: model_version,
        occurred_at: occurred_at,
        patient_id: patient.id,
        professional_id: professional.id,
        target_behavior_id: target_behavior_id
      })
      |> Repo.insert()
    end
  end

  defp broadcast_ready(target_behavior_id) do
    Phoenix.PubSub.broadcast(
      Alethea.PubSub,
      @topic_prefix <> to_string(target_behavior_id),
      {:ai_proposals_ready, target_behavior_id}
    )
  end

  defp broadcast_failed(target_behavior_id, reason) do
    Phoenix.PubSub.broadcast(
      Alethea.PubSub,
      @topic_prefix <> to_string(target_behavior_id),
      {:ai_proposals_failed, reason}
    )
  end
end
