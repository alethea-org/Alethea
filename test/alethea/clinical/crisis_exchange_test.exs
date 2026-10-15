defmodule Alethea.Clinical.CrisisExchangeTest do
  @moduledoc """
  #399: the crisis-exchange population rule for the journaling history,
  through `Alethea.Clinical.list_conversation_turns/3`. A crisis
  exchange — the triggering inbound and its `crisis_bypass` reply —
  collapses into exactly one neutral placeholder turn; neither the
  trigger's words nor the crisis copy reach the model.

  Each test exercises one branch of the identification rule (risk
  marker, `reply_to_message_id` fallback, and the not-yet-persisted
  reply window).
  """

  use Alethea.DataCase, async: true

  import Ecto.Query

  alias Alethea.{Accounts, Clinical}
  alias Alethea.Clinical.{CrisisExchange, Message}

  setup do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "crisis-#{System.unique_integer([:positive])}@alethea.com",
        password: "password1234",
        full_name: "Dra. Crisis"
      })

    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{"alias" => "Paciente Crisis", "professional_id" => professional.id},
        kek
      )

    %{patient: patient}
  end

  describe "list_conversation_turns/3 — crisis exchanges (#399)" do
    test "collapses the trigger and its reply into one placeholder turn", %{patient: patient} do
      insert_turn(patient, "inbound", "antes", ~U[2026-02-01 09:00:00Z])
      trigger = insert_turn(patient, "inbound", "disparador", ~U[2026-02-01 09:01:00Z])
      mark_crisis_trigger(trigger)
      reply = insert_turn(patient, "outbound", "copy de crisis", ~U[2026-02-01 09:02:00Z])
      mark_crisis_reply(reply, trigger)
      insert_turn(patient, "outbound", "después", ~U[2026-02-01 09:03:00Z])
      current = insert_turn(patient, "inbound", "actual", ~U[2026-02-01 09:04:00Z])

      assert {:ok, turns} = Clinical.list_conversation_turns(patient, current, 10)

      assert turns == [
               %{role: :patient, content: "antes"},
               CrisisExchange.placeholder_turn(),
               %{role: :alethea, content: "después"}
             ]
    end

    test "identifies the trigger by its risk marker with no reply yet", %{patient: patient} do
      insert_turn(patient, "inbound", "antes", ~U[2026-02-01 09:00:00Z])
      trigger = insert_turn(patient, "inbound", "disparador", ~U[2026-02-01 09:01:00Z])
      mark_crisis_trigger(trigger)
      current = insert_turn(patient, "inbound", "actual", ~U[2026-02-01 09:04:00Z])

      assert {:ok, turns} = Clinical.list_conversation_turns(patient, current, 10)

      assert turns == [%{role: :patient, content: "antes"}, CrisisExchange.placeholder_turn()]
    end

    test "identifies a legacy trigger through its crisis reply", %{patient: patient} do
      trigger = insert_turn(patient, "inbound", "disparador", ~U[2026-02-01 09:01:00Z])
      reply = insert_turn(patient, "outbound", "copy de crisis", ~U[2026-02-01 09:02:00Z])
      mark_crisis_reply(reply, trigger)
      current = insert_turn(patient, "inbound", "actual", ~U[2026-02-01 09:04:00Z])

      assert {:ok, turns} = Clinical.list_conversation_turns(patient, current, 10)

      assert turns == [CrisisExchange.placeholder_turn()]
    end

    test "identifies a legacy trigger whose reply sorts after the current", %{patient: patient} do
      trigger = insert_turn(patient, "inbound", "disparador", ~U[2026-02-01 09:01:00Z])
      current = insert_turn(patient, "inbound", "actual", ~U[2026-02-01 09:02:00Z])
      reply = insert_turn(patient, "outbound", "copy de crisis", ~U[2026-02-01 09:03:00Z])
      mark_crisis_reply(reply, trigger)

      assert {:ok, turns} = Clinical.list_conversation_turns(patient, current, 10)

      assert turns == [CrisisExchange.placeholder_turn()]
    end

    test "keeps inbounds covered by the crisis reply as ordinary turns", %{patient: patient} do
      absorbed = insert_turn(patient, "inbound", "burst", ~U[2026-02-01 09:00:00Z])
      trigger = insert_turn(patient, "inbound", "disparador", ~U[2026-02-01 09:01:00Z])
      mark_crisis_trigger(trigger)
      reply = insert_turn(patient, "outbound", "copy de crisis", ~U[2026-02-01 09:02:00Z])
      mark_crisis_reply(reply, trigger)
      mark_covered(absorbed, reply)
      current = insert_turn(patient, "inbound", "actual", ~U[2026-02-01 09:04:00Z])

      assert {:ok, turns} = Clinical.list_conversation_turns(patient, current, 10)

      assert turns == [%{role: :patient, content: "burst"}, CrisisExchange.placeholder_turn()]
    end

    test "an ordinary exchange is unaffected", %{patient: patient} do
      insert_turn(patient, "inbound", "hola", ~U[2026-02-01 09:00:00Z])
      insert_turn(patient, "outbound", "bien", ~U[2026-02-01 09:01:00Z])
      current = insert_turn(patient, "inbound", "adiós", ~U[2026-02-01 09:02:00Z])

      assert {:ok, turns} = Clinical.list_conversation_turns(patient, current, 10)

      assert turns == [%{role: :patient, content: "hola"}, %{role: :alethea, content: "bien"}]
    end
  end

  defp insert_turn(patient, direction, text, timestamp) do
    behavior_type = if direction == "inbound", do: "spontaneous", else: "elicited"
    {:ok, message} = Clinical.save_message(patient, text, nil, direction, behavior_type)

    Repo.update_all(from(m in Message, where: m.id == ^message.id), set: [timestamp: timestamp])
    Repo.get!(Message, message.id)
  end

  defp mark_crisis_trigger(%Message{} = trigger) do
    Repo.update_all(from(m in Message, where: m.id == ^trigger.id),
      set: [risk_signal: %{"category" => "confirmed_crisis"}]
    )
  end

  defp mark_crisis_reply(%Message{} = reply, %Message{} = trigger) do
    Repo.update_all(from(m in Message, where: m.id == ^reply.id),
      set: [behavior_type: "crisis_bypass", reply_to_message_id: trigger.id]
    )
  end

  defp mark_covered(%Message{} = inbound, %Message{} = reply) do
    Repo.update_all(from(m in Message, where: m.id == ^inbound.id),
      set: [replied_by_message_id: reply.id]
    )
  end
end
