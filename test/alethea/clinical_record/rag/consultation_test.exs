defmodule Alethea.ClinicalRecord.Rag.ConsultationTest do
  @moduledoc """
  Typed consultation contract (#226a): the facade dispatches to a
  configured implementation, exposes the four `Answer` outcomes plus the
  precondition `{:error, :unauthorized}`, and owns the evidence
  sufficiency threshold. Driven here entirely through `Consultation.Fake`
  — no real retrieval, no LLM.
  """
  use ExUnit.Case, async: false

  alias Alethea.Accounts.Professional
  alias Alethea.ClinicalRecord.Rag.Consultation
  alias Alethea.ClinicalRecord.Rag.Consultation.{Answer, Source}

  setup do
    previous = Application.get_env(:alethea, :clinical_consultation)
    Application.put_env(:alethea, :clinical_consultation, Consultation.Fake)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:alethea, :clinical_consultation)
        value -> Application.put_env(:alethea, :clinical_consultation, value)
      end

      Application.delete_env(:alethea, :consultation_fake_outcome)
    end)

    %{professional: %Professional{id: Ecto.UUID.generate()}, patient_id: Ecto.UUID.generate()}
  end

  describe "answer/4 — typed consultation outcome contract" do
    test "synthesis carries non-empty prose and a non-empty server-derived sources list", ctx do
      assert {:ok, %Answer{outcome: :synthesis} = answer} =
               Consultation.answer(ctx.professional, ctx.patient_id, "¿cómo va el ánimo?",
                 outcome: :synthesis
               )

      assert is_binary(answer.synthesis) and answer.synthesis != ""
      assert [%Source{} | _] = answer.sources
      assert Enum.all?(answer.sources, &match?(%Source{excerpt: e} when is_binary(e), &1))
    end

    for outcome <- [:no_evidence, :provider_failure] do
      test "#{outcome} is a blocking outcome with no prose and no sources", ctx do
        assert {:ok, %Answer{outcome: unquote(outcome), synthesis: nil, sources: []}} =
                 Consultation.answer(ctx.professional, ctx.patient_id, "q",
                   outcome: unquote(outcome)
                 )
      end
    end

    test "stale blocks, carries the pending job count, and attempts no synthesis", ctx do
      assert {:ok, %Answer{outcome: :stale, synthesis: nil, sources: [], pending: pending}} =
               Consultation.answer(ctx.professional, ctx.patient_id, "q",
                 outcome: :stale,
                 pending: 3
               )

      assert pending == 3
    end

    test "unauthorized is a precondition failure, distinct from the four outcomes", ctx do
      assert {:error, :unauthorized} =
               Consultation.answer(ctx.professional, ctx.patient_id, "q", outcome: :unauthorized)
    end
  end

  describe "evidence_threshold/0" do
    test "defaults to 0.35" do
      Application.delete_env(:alethea, :consultation_evidence_threshold)
      assert Consultation.evidence_threshold() == 0.35
    after
      Application.put_env(:alethea, :consultation_evidence_threshold, 0.35)
    end

    test "reflects an application config override round-trip" do
      assert Application.get_env(:alethea, :consultation_evidence_threshold) == 0.35
      Application.put_env(:alethea, :consultation_evidence_threshold, 0.5)
      assert Consultation.evidence_threshold() == 0.5
    after
      Application.put_env(:alethea, :consultation_evidence_threshold, 0.35)
    end
  end

  describe "open/2 — mount authorization path" do
    test "returns idle metadata for the treating professional", ctx do
      assert {:ok, %{chunk_count: chunk_count, freshness: freshness}} =
               Consultation.open(ctx.professional, ctx.patient_id)

      assert is_integer(chunk_count) and chunk_count >= 0
      assert %{stale?: stale?} = freshness
      assert is_boolean(stale?)
    end

    test "returns {:error, :unauthorized} for a stranger", ctx do
      Application.put_env(:alethea, :consultation_fake_outcome, :unauthorized)
      assert {:error, :unauthorized} = Consultation.open(ctx.professional, ctx.patient_id)
    end
  end
end
