defmodule Alethea.Telegram.JobPayload do
  @moduledoc """
  Keeps patient content out of plaintext `oban_jobs.args` (security audit
  run-1, S4).

  Oban persists job args as plaintext JSONB, and completed rows stay in
  the table until `Oban.Plugins.Pruner` removes them (and in backups after
  that). The Telegram workers therefore never store the inbound message
  map, the outbound reply body or the raw `chat_id` in clear: each
  sensitive field `field` is stored as `"encrypted_<field>"`, the
  base64 of the JSON-encoded value encrypted with the global
  `Alethea.Encryption.Vault` (AES-256-GCM, random IV per value).

  Routing keys stay in clear because Oban uniqueness and the workers'
  own queries read them: `telegram_update_id`, `patient_id`,
  `chat_id_hash`, `message_id`, `session_id`, `lane`, `priority`.

  ## Backward compatibility

  `fetch!/2` and `get/3` accept both shapes: an `"encrypted_<field>"`
  value is decrypted; otherwise the legacy plaintext `"<field>"` (or the
  atom `:<field>` of an in-process call) is returned. Jobs enqueued before
  this change keep working.

  Sealing is applied in each worker's `new/2`, so every enqueuer is
  covered without knowing about it.
  """

  alias Alethea.Encryption.Vault

  @doc """
  Replaces each of `fields` present in `args` (atom or string key) with its
  sealed `"encrypted_<field>"` form. Fields that are absent, or already
  sealed, are left alone.
  """
  @spec seal_fields(map(), [atom()]) :: map()
  def seal_fields(args, fields) when is_map(args) and is_list(fields) do
    Enum.reduce(fields, args, fn field, acc ->
      key = Atom.to_string(field)

      cond do
        Map.has_key?(acc, key) ->
          {value, rest} = Map.pop(acc, key)
          Map.put(rest, "encrypted_" <> key, seal(value))

        Map.has_key?(acc, field) ->
          {value, rest} = Map.pop(acc, field)
          Map.put(rest, "encrypted_" <> key, seal(value))

        true ->
          acc
      end
    end)
  end

  @doc "Encrypts a JSON-encodable value into a base64 string."
  @spec seal(term()) :: String.t()
  def seal(value) do
    value
    |> Jason.encode!()
    |> Vault.encrypt!()
    |> Base.encode64()
  end

  @doc "Decrypts a value produced by `seal/1`. Raises on a corrupt value."
  @spec open!(String.t()) :: term()
  def open!(sealed) when is_binary(sealed) do
    sealed
    |> Base.decode64!()
    |> Vault.decrypt!()
    |> Jason.decode!()
  end

  @doc """
  The value of `field` in `args`, decrypting the sealed form when present
  and falling back to the legacy plaintext key. Raises when neither exists.
  """
  @spec fetch!(map(), atom()) :: term()
  def fetch!(args, field) do
    case lookup(args, field) do
      {:ok, value} -> value
      :error -> raise KeyError, key: field, term: Map.keys(args)
    end
  end

  @doc "Like `fetch!/2`, returning `default` when the field is absent."
  @spec get(map(), atom(), term()) :: term()
  def get(args, field, default \\ nil) do
    case lookup(args, field) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc """
  `args` with every sealed `"encrypted_<field>"` replaced by its plaintext
  `"<field>"`. For tests and diagnostics; workers read single fields with
  `fetch!/2` / `get/3`.
  """
  @spec open_fields(map()) :: map()
  def open_fields(args) when is_map(args) do
    Map.new(args, fn
      {"encrypted_" <> field, sealed} when is_binary(sealed) -> {field, open!(sealed)}
      {key, value} -> {key, value}
    end)
  end

  defp lookup(args, field) do
    key = Atom.to_string(field)

    cond do
      is_binary(Map.get(args, "encrypted_" <> key)) ->
        {:ok, open!(Map.fetch!(args, "encrypted_" <> key))}

      Map.has_key?(args, key) ->
        {:ok, Map.fetch!(args, key)}

      Map.has_key?(args, field) ->
        {:ok, Map.fetch!(args, field)}

      true ->
        :error
    end
  end
end
