defmodule Alethea.ClinicalRecord.SessionTranscriptTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias Alethea.ClinicalRecord.SessionTranscript

  @valid_attrs %{
    encrypted_spans: <<1, 2, 3>>,
    recorded_at: ~U[2026-09-24 12:00:00.000000Z],
    patient_id: Ecto.UUID.generate(),
    professional_id: Ecto.UUID.generate()
  }

  describe "changeset/2 — happy path" do
    test "is valid with all required fields" do
      changeset = SessionTranscript.changeset(%SessionTranscript{}, @valid_attrs)

      assert changeset.valid?
      assert get_change(changeset, :encrypted_spans) == <<1, 2, 3>>
      assert get_change(changeset, :recorded_at) == @valid_attrs.recorded_at
      assert get_change(changeset, :patient_id) == @valid_attrs.patient_id
      assert get_change(changeset, :professional_id) == @valid_attrs.professional_id
    end

    test "audio_duration_seconds is optional and castable" do
      changeset_without =
        SessionTranscript.changeset(%SessionTranscript{}, @valid_attrs)

      assert changeset_without.valid?
      assert get_change(changeset_without, :audio_duration_seconds) == nil

      changeset_with =
        SessionTranscript.changeset(
          %SessionTranscript{},
          Map.put(@valid_attrs, :audio_duration_seconds, 754)
        )

      assert changeset_with.valid?
      assert get_change(changeset_with, :audio_duration_seconds) == 754
    end
  end

  # Table-driven required-fields matrix — one row per required field.
  @required_fields [:encrypted_spans, :recorded_at, :patient_id, :professional_id]

  for field <- @required_fields do
    @field field

    test "changeset/2 rejects a missing #{@field}" do
      changeset =
        SessionTranscript.changeset(%SessionTranscript{}, Map.delete(@valid_attrs, @field))

      refute changeset.valid?
      assert "can't be blank" in Map.fetch!(errors_on(changeset), @field)
    end
  end

  describe "plaintext :spans is never castable" do
    test "passing spans: leaves :spans absent from changes" do
      changeset =
        SessionTranscript.changeset(
          %SessionTranscript{},
          Map.put(@valid_attrs, :spans, [%{start: 0.0, end: 1.0, speaker: "patient", text: "hi"}])
        )

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :spans)
    end
  end

  describe "encryption_version defaults to 2 (AD3)" do
    test "defaults without being passed" do
      changeset = SessionTranscript.changeset(%SessionTranscript{}, @valid_attrs)

      refute Map.has_key?(changeset.changes, :encryption_version)
      assert Ecto.Changeset.apply_changes(changeset).encryption_version == 2
    end
  end

  describe "inspect/1 redacts :spans" do
    test "a struct with populated :spans does not leak span text via inspect" do
      transcript = %SessionTranscript{
        spans: [%{start: 0.0, end: 1.0, speaker: "patient", text: "sensitive clinical content"}]
      }

      refute inspect(transcript) =~ "sensitive clinical content"
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
