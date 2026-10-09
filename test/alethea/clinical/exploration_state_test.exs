defmodule Alethea.Clinical.ExplorationStateTest do
  # #393 S1 (design §2): `exploration_state/3`'s reset rules, the
  # `before_snapshot/3` bound it shares with `turns_before/3`, and the
  # retry-stability guarantee (failed/ambiguous replies still count;
  # only `superseded` is excluded). Nothing calls this function from
  # production code yet — this suite proves the read-side contract in
  # isolation ahead of S2/S3 wiring it in.
  use Alethea.DataCase, async: true

  import Ecto.Query

  alias Alethea.{Accounts, Clinical}
  alias Alethea.Clinical.{Message, Session}

  setup do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "exploration-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dra. Exploracion"
      })

    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{"alias" => "Paciente Exploracion", "professional_id" => professional.id},
        kek
      )

    session = session_fixture(patient)
    other_session = session_fixture(patient)

    %{patient: patient, session: session, other_session: other_session}
  end

  describe "exploration_state/3" do
    test "returns fresh state when the snapshot has no outbound reply at all", %{
      patient: patient,
      session: session
    } do
      current = insert_inbound(patient, session.id, ~U[2026-03-01 10:00:00Z])

      assert Clinical.exploration_state(patient, current, session.id) ==
               %{questions: 0, closing_invitation_sent: false}
    end

    test "returns the newest outbound reply's stored counters", %{
      patient: patient,
      session: session
    } do
      insert_outbound(patient, session.id, ~U[2026-03-01 10:00:00Z],
        exploration_questions: 2,
        closing_invitation_sent: false
      )

      current = insert_inbound(patient, session.id, ~U[2026-03-01 10:01:00Z])

      assert Clinical.exploration_state(patient, current, session.id) ==
               %{questions: 2, closing_invitation_sent: false}
    end

    # Trim lever (task 1.7): the four reset rules share one shape —
    # some property of the newest outbound reply makes it ineligible,
    # so the state restarts at `{0, false}` — table-driven here.
    for {name, row_opts, current_session_id} <- [
          {"the newest outbound reply is a crisis_bypass reply",
           [
             behavior_type: "crisis_bypass",
             exploration_questions: 3,
             closing_invitation_sent: true
           ], :same},
          {"the newest outbound reply's session differs from the current session",
           [exploration_questions: 3, closing_invitation_sent: true], :other},
          {"the current session id is nil",
           [exploration_questions: 3, closing_invitation_sent: true], nil},
          {"the newest outbound reply predates this migration (legacy nil counters)", [], :same}
        ] do
      test "resets to fresh state when #{name}", %{
        patient: patient,
        session: session,
        other_session: other_session
      } do
        row_opts = unquote(row_opts)
        current_session_id = unquote(current_session_id)

        insert_outbound(patient, session.id, ~U[2026-03-01 10:00:00Z], row_opts)
        current = insert_inbound(patient, session.id, ~U[2026-03-01 10:01:00Z])

        target_session_id = resolve_session_id(current_session_id, session, other_session)

        assert Clinical.exploration_state(patient, current, target_session_id) ==
                 %{questions: 0, closing_invitation_sent: false}
      end
    end

    test "skips a superseded newest outbound reply, falling back to the one before it", %{
      patient: patient,
      session: session
    } do
      insert_outbound(patient, session.id, ~U[2026-03-01 10:00:00Z],
        exploration_questions: 1,
        closing_invitation_sent: false
      )

      insert_outbound(patient, session.id, ~U[2026-03-01 10:01:00Z],
        exploration_questions: 3,
        closing_invitation_sent: true,
        delivery_state: "superseded"
      )

      current = insert_inbound(patient, session.id, ~U[2026-03-01 10:02:00Z])

      assert Clinical.exploration_state(patient, current, session.id) ==
               %{questions: 1, closing_invitation_sent: false}
    end

    for state <- ["failed", "ambiguous"] do
      test "counts a #{state} newest outbound reply instead of skipping it", %{
        patient: patient,
        session: session
      } do
        state = unquote(state)

        insert_outbound(patient, session.id, ~U[2026-03-01 10:00:00Z],
          exploration_questions: 2,
          closing_invitation_sent: false,
          delivery_state: state
        )

        current = insert_inbound(patient, session.id, ~U[2026-03-01 10:01:00Z])

        assert Clinical.exploration_state(patient, current, session.id) ==
                 %{questions: 2, closing_invitation_sent: false}
      end
    end

    test "ignores an outbound reply that postdates `current`, bounding the snapshot at the earliest member",
         %{patient: patient, session: session} do
      insert_outbound(patient, session.id, ~U[2026-03-01 10:00:00Z],
        exploration_questions: 1,
        closing_invitation_sent: false
      )

      current = insert_inbound(patient, session.id, ~U[2026-03-01 10:01:00Z])

      insert_outbound(patient, session.id, ~U[2026-03-01 10:02:00Z],
        exploration_questions: 3,
        closing_invitation_sent: true
      )

      assert Clinical.exploration_state(patient, current, session.id) ==
               %{questions: 1, closing_invitation_sent: false}
    end
  end

  defp resolve_session_id(:same, session, _other), do: session.id
  defp resolve_session_id(:other, _session, other), do: other.id
  defp resolve_session_id(nil, _session, _other), do: nil

  defp session_fixture(patient) do
    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        started_at: DateTime.utc_now() |> DateTime.truncate(:second),
        status: "open",
        patient_id: patient.id
      })
      |> Repo.insert()

    session
  end

  defp insert_inbound(patient, session_id, timestamp) do
    {:ok, message} =
      Clinical.save_message(patient, "inbound", nil, "inbound", "spontaneous", session_id)

    set_timestamp(message, timestamp)
  end

  defp insert_outbound(patient, session_id, timestamp, opts) do
    behavior_type = Keyword.get(opts, :behavior_type, "elicited")

    {:ok, message} =
      Clinical.save_message(patient, "outbound", nil, "outbound", behavior_type, session_id)

    updates =
      [timestamp: timestamp]
      |> maybe_put(:exploration_questions, Keyword.get(opts, :exploration_questions))
      |> maybe_put(:closing_invitation_sent, Keyword.get(opts, :closing_invitation_sent))
      |> maybe_put(:delivery_state, Keyword.get(opts, :delivery_state))

    Repo.update_all(from(m in Message, where: m.id == ^message.id), set: updates)
    Repo.get!(Message, message.id)
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp set_timestamp(%Message{} = message, timestamp) do
    Repo.update_all(from(m in Message, where: m.id == ^message.id), set: [timestamp: timestamp])
    Repo.get!(Message, message.id)
  end
end
