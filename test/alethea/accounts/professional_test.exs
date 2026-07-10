defmodule Alethea.Accounts.ProfessionalTest do
  @moduledoc """
  Tests for `Alethea.Accounts.Professional`'s `welcome_message` field
  (`professional-welcome-message`, TASK-1).

  Mirrors the existing `crisis_message` field: nullable string,
  editable via `Alethea.Accounts.update_professional/2`. Verified
  behavior (not an assumption): `Ecto.Changeset.cast/4`'s default
  `empty_values: [""]` normalizes an empty string to `nil` for both
  fields — this is Ecto's own default, no custom app code involved.
  """

  use Alethea.DataCase, async: true

  alias Alethea.Accounts
  alias Alethea.Accounts.Professional

  setup do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "welcome-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Welcome"
      })

    %{professional: professional}
  end

  describe "welcome_message field" do
    test "defaults to nil for a newly created professional", %{professional: professional} do
      assert professional.welcome_message == nil
    end

    test "update_professional/2 sets a custom welcome_message", %{professional: professional} do
      assert {:ok, updated} =
               Accounts.update_professional(professional, %{
                 welcome_message: "¡Bienvenido a Alethea!"
               })

      assert updated.welcome_message == "¡Bienvenido a Alethea!"
    end

    # `Ecto.Changeset.cast/4`'s default `empty_values: [""]` normalizes ""
    # to `nil` for every string field cast through `Professional.changeset/2`
    # — verified this is ALSO crisis_message's real behavior (tested the
    # same cast call with `crisis_message`), which contradicts the design
    # doc's assumption that crisis_message has no empty-to-nil
    # normalization. `welcome_message` intentionally mirrors the real,
    # verified behavior rather than the assumed one.
    test "update_professional/2 clearing welcome_message with an empty string resolves to nil",
         %{professional: professional} do
      {:ok, professional} =
        Accounts.update_professional(professional, %{welcome_message: "Custom message"})

      assert {:ok, cleared} = Accounts.update_professional(professional, %{welcome_message: ""})
      assert cleared.welcome_message == nil
    end

    test "welcome_message over 4096 chars fails changeset validation" do
      too_long = String.duplicate("a", 4097)

      changeset =
        Professional.changeset(%Professional{}, %{
          email: "welcome-toolong-#{System.unique_integer([:positive])}@alethea.com",
          password: "supersecret12",
          full_name: "Dr. Welcome",
          welcome_message: too_long
        })

      refute changeset.valid?
      assert "should be at most 4096 character(s)" in errors_on(changeset).welcome_message
    end

    # Judgment Day (welcome-message batch): a real DB round-trip at
    # exactly 4096 chars used to crash with
    # `Postgrex.Error: value too long for type character varying(255)` —
    # the migration originally added `welcome_message` as `:string`
    # (Ecto/Postgres default `varchar(255)`), so any value between 256
    # and 4096 chars passed this changeset's own `validate_length` rule
    # but still failed at the DB layer. Fixed by changing the migration
    # to `:text` (unbounded, matching `crisis_message`'s column type).
    # This test now goes through the real `create_professional/1` DB
    # write, not just the in-memory changeset, so it actually proves the
    # fix and would fail again if the column type regressed.
    test "welcome_message with exactly 4096 chars saves through a real DB round-trip" do
      exactly_max = String.duplicate("a", 4096)

      assert {:ok, professional} =
               Accounts.create_professional(%{
                 email: "welcome-exactmax-#{System.unique_integer([:positive])}@alethea.com",
                 password: "supersecret12",
                 full_name: "Dr. Welcome",
                 welcome_message: exactly_max
               })

      assert professional.welcome_message == exactly_max
    end
  end

  describe "password required on create (regression)" do
    # Regression test for `validate_password_required/2`: `:password`
    # must still be required when `professional.id == nil` (creation).
    # This only guards the create path — `validate_password_required/2`
    # deliberately skips the check once a professional is persisted
    # (partial updates like `save_welcome_message` don't resend
    # `:password`).
    test "create_professional/1 without a password is rejected" do
      assert {:error, changeset} =
               Accounts.create_professional(%{
                 email: "no-password-#{System.unique_integer([:positive])}@alethea.com",
                 full_name: "Dr. No Password"
               })

      assert "can't be blank" in errors_on(changeset).password
    end
  end
end
