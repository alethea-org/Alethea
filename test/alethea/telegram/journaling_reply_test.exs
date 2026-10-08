defmodule Alethea.Telegram.JournalingReplyTest do
  @moduledoc """
  Unit tests for `Alethea.Telegram.JournalingReply.generate_burst/2`
  (#391, S1). `generate/3` is a thin delegate —
  `generate_burst(p, [{inbound, text}])` — exercised here through the
  single-member case.

  R9 (burst generation input): every covered member's sanitized text
  is supplied to the AI worker exactly once, in order, joined by
  `"\\n\\n"`; the anchor (`message_id`) is the newest member (design
  AD8). History is bounded at the earliest member, so no member of
  the burst ever appears in its own history.
  """

  use Alethea.DataCase, async: false
  import Mox
  import Ecto.Query
  import Alethea.FoundationTestHelper

  alias Alethea.Clinical
  alias Alethea.Clinical.Message
  alias Alethea.Telegram.JournalingReply

  setup :verify_on_exit!

  setup do
    legacy_professional = legacy_professional_fixture()
    legacy_patient = legacy_patient_fixture(legacy_professional)

    foundation_patient =
      professional_fixture()
      |> patient_fixture()
      |> Ecto.Changeset.change(%{legacy_patient_id: legacy_patient.id})
      |> Repo.update!()

    %{foundation_patient: foundation_patient, legacy_patient: legacy_patient}
  end

  test "supplies every member once, in order, joined by a blank line, anchored on the newest, history bounded at the earliest",
       %{foundation_patient: foundation_patient, legacy_patient: legacy_patient} do
    insert_turn(legacy_patient, "outbound", "previo", ~U[2026-03-01 09:00:00Z])

    first = insert_turn(legacy_patient, "inbound", "primero", ~U[2026-03-01 09:01:00Z])
    second = insert_turn(legacy_patient, "inbound", "segundo", ~U[2026-03-01 09:02:00Z])
    third = insert_turn(legacy_patient, "inbound", "tercero", ~U[2026-03-01 09:03:00Z])

    members = [{first, "primero"}, {second, "segundo"}, {third, "tercero"}]

    Alethea.AI.PhiWorkerMock
    |> expect(:process, fn request ->
      assert request.message_id == third.id
      assert request.sanitized_content == "primero\n\nsegundo\n\ntercero"
      assert request.history == [%{role: :alethea, content: "previo"}]

      {:ok, %{response: "respuesta burst"}}
    end)

    assert {:ok, %{response: "respuesta burst"}} =
             JournalingReply.generate_burst(foundation_patient, members)
  end

  test "generate/3 delegates to generate_burst/2 with a single-member list", %{
    foundation_patient: foundation_patient,
    legacy_patient: legacy_patient
  } do
    inbound = insert_turn(legacy_patient, "inbound", "unico", ~U[2026-03-01 10:00:00Z])

    Alethea.AI.PhiWorkerMock
    |> expect(:process, fn request ->
      assert request.message_id == inbound.id
      assert request.sanitized_content == "unico"
      assert request.history == []

      {:ok, %{response: "respuesta simple"}}
    end)

    assert {:ok, %{response: "respuesta simple"}} =
             JournalingReply.generate(foundation_patient, inbound, "unico")
  end

  defp insert_turn(legacy_patient, direction, text, timestamp) do
    behavior_type = if direction == "inbound", do: "spontaneous", else: "elicited"
    {:ok, message} = Clinical.save_message(legacy_patient, text, nil, direction, behavior_type)

    Repo.update_all(from(m in Message, where: m.id == ^message.id), set: [timestamp: timestamp])
    Repo.get!(Message, message.id)
  end
end
