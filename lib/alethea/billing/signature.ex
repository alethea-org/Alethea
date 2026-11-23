defmodule Alethea.Billing.Signature do
  @moduledoc """
  Verifies Paddle Billing's `Paddle-Signature` header.

  The header has the form `ts=<unix seconds>;h1=<hex hmac>` (Paddle may
  send several `h1` values while a secret is being rotated). The signed
  payload is `"<ts>:<raw body>"`, HMAC-SHA256 with the notification
  destination's secret key. Comparison is constant-time, and a timestamp
  outside the tolerance window is rejected to limit replays.
  """

  @default_tolerance_seconds 300

  @spec valid?(String.t() | nil, binary() | nil, String.t() | nil, keyword()) :: boolean()
  def valid?(header, raw_body, secret, opts \\ [])

  def valid?(header, raw_body, secret, opts)
      when is_binary(header) and is_binary(raw_body) and is_binary(secret) and secret != "" do
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance_seconds)
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)

    with {:ok, ts, signatures} <- parse(header),
         true <- abs(now - ts) <= tolerance do
      expected = sign(raw_body, ts, secret)
      Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected))
    else
      _ -> false
    end
  end

  def valid?(_header, _raw_body, _secret, _opts), do: false

  @doc "Builds the hex signature Paddle would send for `raw_body` at `ts`."
  @spec sign(binary(), integer(), String.t()) :: String.t()
  def sign(raw_body, ts, secret) do
    :crypto.mac(:hmac, :sha256, secret, "#{ts}:#{raw_body}")
    |> Base.encode16(case: :lower)
  end

  defp parse(header) do
    pairs =
      header
      |> String.split(";", trim: true)
      |> Enum.map(&String.split(&1, "=", parts: 2))

    ts =
      Enum.find_value(pairs, fn
        ["ts", value] -> value
        _ -> nil
      end)

    signatures = for ["h1", value] <- pairs, do: String.downcase(value)

    case ts && Integer.parse(ts) do
      {ts_int, ""} when signatures != [] -> {:ok, ts_int, signatures}
      _ -> :error
    end
  end
end
