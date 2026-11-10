defmodule Alethea.Triggers.PaginationTest do
  use Alethea.DataCase, async: false

  import Alethea.TriggersFixtures

  alias Alethea.Clinical
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo
  alias Alethea.Triggers
  alias Alethea.Triggers.{Trigger, TriggerFiring}

  @base ~U[2026-01-01 12:00:00Z]

  setup do
    fixture_professional_and_patient()
  end

  defp insert_trigger!(professional, patient, kind, index, attrs \\ %{}) do
    {:ok, dek} = Clinical.patient_dek(patient, "test_pagination")
    {:ok, instruction} = PatientVault.encrypt("Instruccion #{kind} #{index}", dek)
    at = DateTime.add(@base, index * 60, :second)

    shape =
      case kind do
        "active" ->
          %{
            scheduled_at: DateTime.add(@base, 86_400, :second),
            timezone: "America/Santiago",
            schedule_type: "once"
          }

        "reactive" ->
          {:ok, condition} = PatientVault.encrypt("Condicion #{index}", dek)
          %{condition: condition, cooldown_hours: 24}
      end

    struct!(
      Trigger,
      Map.merge(
        %{
          patient_id: patient.id,
          professional_id: professional.id,
          instruction: instruction,
          kind: kind,
          status: "inactive",
          inserted_at: at,
          updated_at: at
        },
        Map.merge(shape, attrs)
      )
    )
    |> Repo.insert!()
  end

  defp insert_firing!(trigger, index) do
    fired_at = DateTime.add(@base, index * 60, :second)

    %TriggerFiring{}
    |> TriggerFiring.changeset(%{
      trigger_id: trigger.id,
      status: "skipped",
      fired_at: fired_at,
      scheduled_at: fired_at
    })
    |> Repo.insert!()
  end

  describe "list_triggers_page/3" do
    test "scheduled kind keeps the soonest-first order (scheduled_at asc) across a page boundary",
         %{professional: professional, patient: patient} do
      # Creation order differs from schedule order: 7 is coprime with 25, so
      # rem(i * 7, 25) is a permutation of 0..24.
      active =
        for i <- 1..25 do
          insert_trigger!(professional, patient, "active", i, %{
            scheduled_at: DateTime.add(@base, rem(i * 7, 25) * 86_400, :second)
          })
        end

      expected_ids = active |> Enum.sort_by(& &1.scheduled_at, DateTime) |> Enum.map(& &1.id)

      assert {:ok, %{entries: page1, more?: true, cursor: cursor}} =
               Triggers.list_triggers_page(professional, patient.id, kind: "active")

      assert {:ok, %{entries: page2, more?: false}} =
               Triggers.list_triggers_page(professional, patient.id,
                 kind: "active",
                 before: cursor
               )

      assert Enum.map(page1, & &1.id) == Enum.take(expected_ids, 20)
      assert Enum.map(page2, & &1.id) == Enum.drop(expected_ids, 20)
    end

    test "filters by kind in the query, limited, with has-more flag",
         %{professional: professional, patient: patient} do
      active =
        for i <- 1..25 do
          insert_trigger!(professional, patient, "active", i, %{
            scheduled_at: DateTime.add(@base, i * 86_400, :second)
          })
        end

      _reactive = for i <- 1..3, do: insert_trigger!(professional, patient, "reactive", i)

      assert {:ok, %{entries: page1, more?: true, cursor: cursor}} =
               Triggers.list_triggers_page(professional, patient.id, kind: "active", limit: 20)

      expected_ids = Enum.map(active, & &1.id)

      assert length(page1) == 20
      assert Enum.all?(page1, &(&1.kind == "active"))
      assert Enum.map(page1, & &1.id) == Enum.take(expected_ids, 20)
      assert hd(page1).decrypted_instruction == "Instruccion active 1"

      assert {:ok, %{entries: page2, more?: false}} =
               Triggers.list_triggers_page(professional, patient.id,
                 kind: "active",
                 limit: 20,
                 before: cursor
               )

      assert Enum.map(page2, & &1.id) == Enum.drop(expected_ids, 20)
    end

    test "reactive kind returns only reactive triggers and no more flag when under limit",
         %{professional: professional, patient: patient} do
      _active = for i <- 1..3, do: insert_trigger!(professional, patient, "active", i)
      reactive = for i <- 1..4, do: insert_trigger!(professional, patient, "reactive", i)

      assert {:ok, %{entries: entries, more?: false}} =
               Triggers.list_triggers_page(professional, patient.id, kind: "reactive")

      assert Enum.map(entries, & &1.id) == reactive |> Enum.reverse() |> Enum.map(& &1.id)
    end

    test "default page size is 20", %{professional: professional, patient: patient} do
      for i <- 1..21, do: insert_trigger!(professional, patient, "active", i)

      assert {:ok, %{entries: entries, more?: true}} =
               Triggers.list_triggers_page(professional, patient.id, kind: "active")

      assert length(entries) == 20
    end

    test "ties on inserted_at are broken by id without skipping or duplicating",
         %{professional: professional, patient: patient} do
      same = for _ <- 1..5, do: insert_trigger!(professional, patient, "active", 1)

      assert {:ok, %{entries: p1, more?: true, cursor: c1}} =
               Triggers.list_triggers_page(professional, patient.id, kind: "active", limit: 2)

      assert {:ok, %{entries: p2, more?: true, cursor: c2}} =
               Triggers.list_triggers_page(professional, patient.id,
                 kind: "active",
                 limit: 2,
                 before: c1
               )

      assert {:ok, %{entries: p3, more?: false}} =
               Triggers.list_triggers_page(professional, patient.id,
                 kind: "active",
                 limit: 2,
                 before: c2
               )

      ids = Enum.map(p1 ++ p2 ++ p3, & &1.id)
      assert length(ids) == 5
      assert Enum.sort(ids) == same |> Enum.map(& &1.id) |> Enum.sort()
    end

    test "excludes archived triggers", %{professional: professional, patient: patient} do
      kept = insert_trigger!(professional, patient, "active", 1)

      _archived =
        insert_trigger!(professional, patient, "active", 2, %{archived_at: @base})

      assert {:ok, %{entries: [only], more?: false}} =
               Triggers.list_triggers_page(professional, patient.id, kind: "active")

      assert only.id == kept.id
    end

    test "rejects a patient the professional does not own",
         %{professional: professional} do
      other = fixture_professional_and_patient()

      assert {:error, :unauthorized} =
               Triggers.list_triggers_page(professional, other.patient.id, kind: "active")
    end
  end

  describe "list_firings_page/3" do
    test "newest first, limited, cursor fetches the rest",
         %{professional: professional, patient: patient} do
      trigger = insert_trigger!(professional, patient, "active", 1)
      firings = for i <- 1..25, do: insert_firing!(trigger, i)
      expected_ids = firings |> Enum.reverse() |> Enum.map(& &1.id)

      assert {:ok, %{entries: page1, more?: true, cursor: cursor}} =
               Triggers.list_firings_page(professional, patient.id, limit: 20)

      assert Enum.map(page1, & &1.id) == Enum.take(expected_ids, 20)
      assert %Trigger{} = hd(page1).trigger

      assert {:ok, %{entries: page2, more?: false}} =
               Triggers.list_firings_page(professional, patient.id, limit: 20, before: cursor)

      assert Enum.map(page2, & &1.id) == Enum.drop(expected_ids, 20)
    end

    test "rejects a patient the professional does not own",
         %{professional: professional} do
      other = fixture_professional_and_patient()
      assert {:error, :unauthorized} = Triggers.list_firings_page(professional, other.patient.id)
    end
  end

  describe "existing list functions without opts (unchanged)" do
    test "list_triggers/2 still returns every non-archived trigger of both kinds",
         %{professional: professional, patient: patient} do
      for i <- 1..22, do: insert_trigger!(professional, patient, "active", i)
      for i <- 1..3, do: insert_trigger!(professional, patient, "reactive", i)

      assert {:ok, all} = Triggers.list_triggers(professional, patient.id)
      assert length(all) == 25
    end

    test "list_firings/2 still returns every firing",
         %{professional: professional, patient: patient} do
      trigger = insert_trigger!(professional, patient, "active", 1)
      for i <- 1..25, do: insert_firing!(trigger, i)

      assert {:ok, all} = Triggers.list_firings(professional, patient.id)
      assert length(all) == 25
    end
  end
end
