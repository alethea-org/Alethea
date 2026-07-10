defmodule Alethea.Accounts.ProfessionalTest do
  @moduledoc """
  Tests for `Alethea.Accounts.Professional`'s `welcome_message` field
  (`professional-welcome-message`, TASK-1).

  Mirrors the existing `crisis_message` field: nullable string, cast
  as-is (no empty-to-nil normalization), editable via
  `Alethea.Accounts.update_professional/2`.
  """

  use Alethea.DataCase, async: true

  alias Alethea.Accounts

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
  end
end
