defmodule Alethea.Encryption.Vault do
  use Cloak.Vault, otp_app: :alethea

  @impl GenServer
  def init(config) do
    config =
      Keyword.put(config, :ciphers,
        default: {Cloak.Ciphers.AES.GCM, tag: "AES", key: decode_key(config[:aes_key])}
      )

    {:ok, config}
  end

  defp decode_key(nil), do: nil
  defp decode_key(key), do: Base.decode64!(key)
end
