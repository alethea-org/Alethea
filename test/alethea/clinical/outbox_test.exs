defmodule Alethea.Clinical.OutboxTest do
  @moduledoc """
  Tests for `Alethea.Clinical.Outbox` (sdd/telegram-rag-ingestion-262,
  Slice 1, Phase 1). Mirrors `Alethea.ClinicalRecord.OutboxTest`'s shape:
  proves the `Map.take/2` allowlist over a `Alethea.Clinical.Message`
  struct, and that a `nil` `professional_id` fails loudly (AD5) instead
  of silently enqueueing an unusable job.
  """
  use ExUnit.Case, async: true

  alias Alethea.Clinical.{Message, Outbox}

  describe "event/3 — patient_message_received" do
    test "builds a job changeset with identifiers-only args and no message content" do
      id = Ecto.UUID.generate()
      patient_id = Ecto.UUID.generate()
      professional_id = Ecto.UUID.generate()

      message = %Message{
        id: id,
        patient_id: patient_id,
        direction: "inbound",
        encrypted_content: <<1, 2, 3>>
      }

      changeset = Outbox.event("patient_message_received", message, professional_id)

      assert changeset.valid?

      assert get_change(changeset, :args) == %{
               "event" => "patient_message_received",
               "resource_type" => "patient_message",
               "resource_id" => id,
               "patient_id" => patient_id,
               "professional_id" => professional_id
             }
    end
  end

  describe "event/3 — allowlist drops non-identifier keys (triangulation)" do
    test "args never contains encrypted_content even if the message shape widens" do
      id = Ecto.UUID.generate()
      patient_id = Ecto.UUID.generate()
      professional_id = Ecto.UUID.generate()

      message = %Message{
        id: id,
        patient_id: patient_id,
        direction: "inbound",
        encrypted_content: <<9, 9, 9>>,
        telegram_message_id: "tg-123"
      }

      changeset = Outbox.event("patient_message_received", message, professional_id)
      args = get_change(changeset, :args)

      assert Map.keys(args) |> Enum.sort() ==
               Enum.sort([
                 "event",
                 "resource_type",
                 "resource_id",
                 "patient_id",
                 "professional_id"
               ])

      refute Map.has_key?(args, "encrypted_content")
      refute Map.has_key?(args, "telegram_message_id")
    end

    test "targets AletheaJobs.ClinicalRecordOutboxWorker" do
      message = %Message{
        id: Ecto.UUID.generate(),
        patient_id: Ecto.UUID.generate(),
        direction: "inbound",
        encrypted_content: <<1>>
      }

      changeset = Outbox.event("patient_message_received", message, Ecto.UUID.generate())

      assert Ecto.Changeset.get_field(changeset, :worker) ==
               "AletheaJobs.ClinicalRecordOutboxWorker"
    end
  end

  describe "event/3 — AD5: nil professional_id fails loudly" do
    test "raises FunctionClauseError instead of silently building an unusable job" do
      message = %Message{
        id: Ecto.UUID.generate(),
        patient_id: Ecto.UUID.generate(),
        direction: "inbound",
        encrypted_content: <<1>>
      }

      assert_raise FunctionClauseError, fn ->
        Outbox.event("patient_message_received", message, nil)
      end
    end
  end

  defp get_change(%Ecto.Changeset{} = changeset, field),
    do: Ecto.Changeset.get_change(changeset, field)
end
