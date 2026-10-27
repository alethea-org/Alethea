defmodule Alethea.Jobs.TelegramMessageWorkerCrisisCopyTest do
  @moduledoc """
  Crisis-copy fallback through the worker seam (#394, S0, task 0.4).

  Every crisis test in `telegram_message_worker_test.exs` seeds a
  `crisis_message`, so the fallback chain resolved by
  `Alethea.Alerts.CrisisCopy` (nil -> `:crisis_support_message` -> default)
  was never exercised end to end. These tests drive
  `TelegramMessageWorker.perform/1` with a professional whose
  `crisis_message` is `nil` and assert the persisted crisis outbound body.
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo
  import Mox

  alias Alethea.Alerts.CrisisCopy
  alias Alethea.Clinical.Message
  alias Alethea.Jobs.TelegramMessageWorker
  alias Alethea.Repo
  alias Alethea.Telegram.ChatIdHash

  import Alethea.FoundationTestHelper
  import Ecto.Query

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 123_456_789
  @chat_id_hash ChatIdHash.hash(@chat_id, @pepper)
  @crisis_text "me voy a quitar la vida"

  setup :verify_on_exit!

  setup do
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    Repo.delete_all(Oban.Job)

    previous = Application.fetch_env(:alethea, :crisis_support_message)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:alethea, :crisis_support_message, value)
        :error -> Application.delete_env(:alethea, :crisis_support_message)
      end
    end)

    bind_patient_without_crisis_message()
  end

  describe "perform/1 — crisis branch, professional without crisis_message" do
    test "sends the :crisis_support_message config text" do
      Application.put_env(:alethea, :crisis_support_message, "Texto de apoyo configurado.")

      assert :ok = perform_crisis_inbound()

      assert crisis_outbound_body() == "Texto de apoyo configurado."
    end

    test "sends the system default when no config is set" do
      Application.delete_env(:alethea, :crisis_support_message)

      assert :ok = perform_crisis_inbound()

      assert crisis_outbound_body() == CrisisCopy.default_support_message()
    end
  end

  defp perform_crisis_inbound do
    TelegramMessageWorker.perform(%Oban.Job{
      args: %{
        "telegram_update_id" => 91,
        "message" => %{
          "message_id" => 901,
          "date" => 1_700_000_000,
          "chat" => %{"id" => @chat_id, "type" => "private"},
          "text" => @crisis_text
        }
      }
    })
  end

  defp crisis_outbound_body do
    outbound =
      Repo.one!(
        from m in Message, where: m.direction == "outbound" and m.behavior_type == "crisis_bypass"
      )

    {:ok, legacy_patient} =
      Alethea.Foundation.Accounts.legacy_patient(
        Repo.get_by!(Alethea.Foundation.Accounts.Patient, legacy_patient_id: outbound.patient_id)
      )

    {:ok, dek} = Alethea.Clinical.patient_dek(legacy_patient)
    {:ok, plaintext} = Alethea.Clinical.decrypt_message_content(outbound, dek)
    plaintext
  end

  defp bind_patient_without_crisis_message do
    foundation_pro = professional_fixture()
    foundation_pat = patient_fixture(foundation_pro, %{alias: "Pat#{unique_int()}"})

    {:ok, legacy_pro} =
      Alethea.Accounts.create_professional(%{
        email: "pro-#{unique_int()}@test.local",
        password: "supersecret12",
        full_name: "Test Pro #{unique_int()}"
      })

    legacy_pro =
      legacy_pro
      |> Ecto.Changeset.change(%{crisis_message: nil})
      |> Repo.update!()

    {:ok, kek} = Alethea.Accounts.load_professional_kek(legacy_pro)

    {:ok, legacy_pat} =
      Alethea.Accounts.create_patient(
        %{"alias" => "alias-#{unique_int()}", "professional_id" => legacy_pro.id},
        kek
      )

    foundation_pat
    |> Ecto.Changeset.change(%{
      telegram_chat_id_hash: @chat_id_hash,
      legacy_patient_id: legacy_pat.id
    })
    |> Repo.update!()

    :ok
  end

  defp unique_int, do: System.unique_integer([:positive])
end
