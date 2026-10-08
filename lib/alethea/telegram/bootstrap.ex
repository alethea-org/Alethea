defmodule Alethea.Telegram.Bootstrap do
  @moduledoc """
  Writes the sealed Telegram `BotConfig` row for one environment.

  This is the single implementation behind `mix alethea.telegram.bootstrap`
  and `Alethea.Release.telegram_bootstrap/0`. It reads three variables:

    * `TELEGRAM_BOT_TOKEN` — the token issued by BotFather
      (`<digits>:<letters, digits, underscores or hyphens>`);
    * `TELEGRAM_WEBHOOK_SECRET` — the value Telegram echoes back in the
      `X-Telegram-Bot-Api-Secret-Token` header; 1 to 256 characters of
      `A-Z a-z 0-9 _ -`, which is the alphabet `setWebhook` accepts;
    * `TELEGRAM_BOT_USERNAME` — 5 to 32 letters, digits or underscores, with
      an optional leading `@` that is dropped before storage.

  ## Idempotency

  Running it again with the same values does not write and reports
  `:unchanged`. Running it with different values rewrites the row in place
  and reports `:updated`; that is the rotation path. A running
  `Alethea.Telegram.BotToken` keeps the previous values until it is reloaded
  or the node restarts.

  ## Secrets

  No function here logs, the query log is silenced around the write (Ecto
  would otherwise print the plaintext parameters at `:debug`), and no return
  value or message carries the token or the webhook secret. Failures are
  fixed tags (a database exception is reduced to its module name); `message/1` turns a tag into a fixed sentence.

  ## Checking without writing

  `verify_stored/1` answers the question a deploy asks when it carries no
  `TELEGRAM_*` values: can the server boot from the row already stored? It
  decrypts the row instead of only counting it, because
  `Alethea.Telegram.BotToken` refuses to start on a row it cannot decrypt
  (a different `CLOAK_AES_KEY`) just as it does on a missing one. The
  plaintext never leaves the function.

  The caller owns the runtime: `Alethea.Repo` and `Alethea.Encryption.Vault`
  must be running.
  """

  alias Alethea.Foundation.Accounts.BotConfig

  @token_var "TELEGRAM_BOT_TOKEN"
  @secret_var "TELEGRAM_WEBHOOK_SECRET"
  @username_var "TELEGRAM_BOT_USERNAME"

  @valid_envs ~w(dev test prod)
  @token_regex ~r/\A[0-9]+:[A-Za-z0-9_-]+\z/
  @secret_regex ~r/\A[A-Za-z0-9_-]{1,256}\z/
  @username_regex ~r/\A[A-Za-z0-9_]{5,32}\z/

  @type attrs :: %{bot_token: String.t(), secret_token: String.t(), bot_username: String.t()}
  @type status :: :created | :updated | :unchanged
  @type result :: %{status: status(), env: String.t(), bot_username: String.t()}
  @type stored :: %{status: :kept, env: String.t(), bot_username: String.t()}
  @type reason ::
          {:missing, String.t()}
          | {:invalid, String.t()}
          | :invalid_env
          | :write_failed
          | {:database_error, module()}
          | :not_configured
          | :unreadable
          | {:read_failed, module()}

  @doc """
  Validates `vars` and writes the row for `env` (`"dev"`, `"test"` or
  `"prod"`). `vars` is a map of environment variable names to values, by
  default the process environment.
  """
  @spec run(String.t(), %{optional(String.t()) => String.t()}) ::
          {:ok, result()} | {:error, reason()}
  def run(env, vars \\ System.get_env()) when is_map(vars) do
    with {:ok, attrs} <- validate(vars) do
      write(env, attrs)
    end
  end

  @doc """
  Validates the three variables without touching the database. Returns the
  normalized attributes, or the first failure.
  """
  @spec validate(%{optional(String.t()) => String.t()}) :: {:ok, attrs()} | {:error, reason()}
  def validate(vars) when is_map(vars) do
    with {:ok, bot_token} <- fetch(vars, @token_var, @token_regex),
         {:ok, secret_token} <- fetch(vars, @secret_var, @secret_regex),
         {:ok, bot_username} <- fetch(vars, @username_var, @username_regex) do
      {:ok, %{bot_token: bot_token, secret_token: secret_token, bot_username: bot_username}}
    end
  end

  @doc """
  Writes already validated attributes for `env`, skipping the write when the
  stored row already holds the same values.
  """
  @spec write(String.t(), attrs()) :: {:ok, result()} | {:error, reason()}
  def write(env, %{bot_token: _, secret_token: _, bot_username: bot_username} = attrs)
      when env in @valid_envs do
    case BotConfig.for_env(env, log: false) do
      {:ok, %BotConfig{} = existing} ->
        if same?(existing, attrs) do
          {:ok, %{status: :unchanged, env: env, bot_username: bot_username}}
        else
          upsert(env, attrs, :updated)
        end

      :not_found ->
        upsert(env, attrs, :created)
    end
  rescue
    # Only the exception module survives: its message and fields are dropped
    # so that nothing derived from a failed write of secret material can
    # reach a log or a caller.
    exception -> {:error, {:database_error, exception.__struct__}}
  catch
    :exit, _reason -> {:error, :write_failed}
  end

  def write(_env, _attrs), do: {:error, :invalid_env}

  @doc """
  Checks, without writing, that the row stored for `env` is one the server
  can boot from: present and decryptable with the running vault.

  Returns `{:error, :not_configured}` when no row exists for `env` and
  `{:error, :unreadable}` when one exists but does not decrypt.
  """
  @spec verify_stored(String.t()) :: {:ok, stored()} | {:error, reason()}
  def verify_stored(env) when env in @valid_envs do
    case BotConfig.for_env(env, log: false) do
      {:ok, %BotConfig{bot_token: bot_token, secret_token: secret_token, bot_username: username}}
      when is_binary(bot_token) and is_binary(secret_token) and is_binary(username) ->
        {:ok, %{status: :kept, env: env, bot_username: username}}

      # A failed authenticated decryption loads as a non-binary field.
      {:ok, %BotConfig{}} ->
        {:error, :unreadable}

      :not_found ->
        {:error, :not_configured}
    end
  rescue
    # Ecto raises this when a sealed column cannot be loaded at all (no
    # cipher in the vault matches it). The message renders the ciphertext
    # and is dropped.
    ArgumentError -> {:error, :unreadable}
    exception -> {:error, {:read_failed, exception.__struct__}}
  catch
    :exit, _reason -> {:error, {:read_failed, :exit}}
  end

  def verify_stored(_env), do: {:error, :invalid_env}

  @doc "Turns a failure tag into a fixed sentence that carries no input value."
  @spec message(reason()) :: String.t()
  def message({:missing, name}) when name in [@token_var, @secret_var, @username_var],
    do: "#{name} is required"

  def message({:invalid, @token_var}),
    do:
      "#{@token_var} must be the BotFather token: digits, a colon, then letters, digits, underscores, or hyphens"

  def message({:invalid, @secret_var}),
    do: "#{@secret_var} must contain 1 to 256 letters, digits, underscores, or hyphens"

  def message({:invalid, @username_var}),
    do: "#{@username_var} must contain 5 to 32 letters, digits, or underscores"

  def message(:invalid_env), do: "the target environment must be dev, test or prod"
  def message(:write_failed), do: "Telegram bot configuration could not be written"

  def message({:database_error, module}) when is_atom(module),
    do: "Telegram bot configuration could not be written (#{inspect(module)})"

  def message(:not_configured),
    do:
      "no Telegram bot configuration is stored for this environment; set #{@token_var}, " <>
        "#{@secret_var} and #{@username_var} and deploy again, or run bin/telegram_bootstrap " <>
        "with them set"

  def message(:unreadable),
    do:
      "the stored Telegram bot configuration cannot be decrypted with the current " <>
        "CLOAK_AES_KEY; restore the key it was written with, or set #{@token_var}, " <>
        "#{@secret_var} and #{@username_var} and run bin/telegram_bootstrap to rewrite it"

  def message({:read_failed, module}) when is_atom(module),
    do: "Telegram bot configuration could not be read (#{inspect(module)})"

  def message(_reason), do: "Telegram bot configuration failed"

  defp fetch(vars, name, regex) do
    case Map.get(vars, name) do
      value when is_binary(value) ->
        value |> String.trim() |> normalize(name) |> check(name, regex)

      _missing ->
        {:error, {:missing, name}}
    end
  end

  defp normalize(value, @username_var), do: String.trim_leading(value, "@")
  defp normalize(value, _name), do: value

  defp check("", name, _regex), do: {:error, {:missing, name}}

  defp check(value, name, regex) do
    if Regex.match?(regex, value), do: {:ok, value}, else: {:error, {:invalid, name}}
  end

  defp same?(%BotConfig{} = existing, attrs) do
    existing.bot_token == attrs.bot_token and
      existing.secret_token == attrs.secret_token and
      existing.bot_username == attrs.bot_username
  end

  defp upsert(env, attrs, status) do
    case without_logging(fn -> BotConfig.upsert(Map.put(attrs, :env, env)) end) do
      {:ok, %BotConfig{}} ->
        {:ok, %{status: status, env: env, bot_username: attrs.bot_username}}

      {:error, _changeset} ->
        {:error, :write_failed}
    end
  end

  # Ecto logs a query with its parameters as cast, before `Cloak.Ecto`
  # encrypts them, so at the `:debug` level the upsert would print the
  # plaintext token and secret. Logging is switched off for this process for
  # the duration of the write, then restored.
  defp without_logging(fun) do
    previous = Logger.get_process_level(self())
    Logger.put_process_level(self(), :none)

    try do
      fun.()
    after
      case previous do
        nil -> Logger.delete_process_level(self())
        level -> Logger.put_process_level(self(), level)
      end
    end
  end
end
