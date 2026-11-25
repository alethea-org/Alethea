defmodule Alethea.Telegram.JobPayloadTest do
  @moduledoc """
  Sealed Telegram job args (security-audit-run-1, S4) that can no longer
  be decrypted, for example after a vault key change or row corruption,
  must end as a visible, terminal outcome instead of an exception that
  silently discards the job.
  """

  use Alethea.DataCase, async: false

  alias Alethea.Jobs.{TelegramMessageWorker, TelegramVoiceNoteWorker}
  alias Alethea.Telegram.JobPayload

  defp corrupted, do: Base.encode64(:crypto.strong_rand_bytes(48))

  describe "fetch/2" do
    test "opens a sealed field" do
      assert {:ok, "hola"} =
               JobPayload.fetch(%{"encrypted_body" => JobPayload.seal("hola")}, :body)
    end

    test "falls back to the legacy plaintext key" do
      assert {:ok, "hola"} = JobPayload.fetch(%{"body" => "hola"}, :body)
    end

    test "reports an undecryptable sealed field instead of raising" do
      assert {:error, :undecryptable} =
               JobPayload.fetch(%{"encrypted_body" => corrupted()}, :body)
    end

    test "reports a value sealed under a cipher label the vault no longer has" do
      {:ok, ciphertext} = Alethea.Encryption.Vault.encrypt("\"hola\"")
      # Rewrite the Cloak label byte header to an unknown label.
      <<_type, len, _label::binary-size(len), rest::binary>> = ciphertext
      foreign = <<1, 7, "retired", rest::binary>>

      assert {:error, :undecryptable} =
               JobPayload.fetch(%{"encrypted_body" => Base.encode64(foreign)}, :body)
    end

    test "reports a missing field" do
      assert :error = JobPayload.fetch(%{}, :body)
    end
  end

  describe "inbound workers with an undecryptable message" do
    setup do
      Phoenix.PubSub.subscribe(Alethea.PubSub, "ops:alerts")
      %{args: %{"telegram_update_id" => 4242, "encrypted_message" => corrupted()}}
    end

    test "TelegramMessageWorker cancels the job and alerts operators", %{args: args} do
      assert {:cancel, :undecryptable_payload} =
               TelegramMessageWorker.perform(%Oban.Job{id: 1, args: args})

      assert_receive {:job_payload_undecryptable,
                      %{worker: "Alethea.Jobs.TelegramMessageWorker", job_id: 1}}
    end

    test "TelegramVoiceNoteWorker cancels the job and alerts operators", %{args: args} do
      job = %Oban.Job{id: 2, args: args, attempt: 1, max_attempts: 3}

      assert {:cancel, :undecryptable_payload} = TelegramVoiceNoteWorker.perform(job)

      assert_receive {:job_payload_undecryptable,
                      %{worker: "Alethea.Jobs.TelegramVoiceNoteWorker", job_id: 2}}
    end
  end
end
