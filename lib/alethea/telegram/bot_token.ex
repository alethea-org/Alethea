defmodule Alethea.Telegram.BotToken do
  @moduledoc """
  GenServer accessor for the sealed Telegram bot config (C-6).

  Loads `Alethea.Foundation.Accounts.BotConfig.for_env(Mix.env())` once at
  boot, holds the plaintext in process state, and serves it via
  synchronous `GenServer.call/2`.

  ## Plaintext boundary

  The plaintext bot token and webhook secret token are reachable
  through the **public API** under normal operation: callers use
  `bot_token/0` and `secret_token/0` (both `GenServer.call/2`) to
  read the live value, and `reload/0` to refresh it. The plaintext
  also lives in the GenServer's process state.

  **The process pid is secret-bearing.** OTP introspection paths
  (`:sys.get_state/1`, `:sys.replace_state/3`, remote-shell
  `Process.info/2`, the `:dictionary` slot) can reach the process
  state and the plaintext. To prevent accidental leakage into a
  log feed or a remote-console dump, this module implements
  `format_status/1` to redact `:bot_token` and `:secret_token` in
  the human-readable status. The redaction is opt-in for tooling
  that respects `format_status/1` (the default `:sys.get_state/1`
  path); raw state access still requires an explicit, privileged
  call (e.g. `:sys.replace_state/3`).

  Treat the BotToken pid as a secret. Do not log it; do not pass it
  across untrusted boundaries; do not include it in error reports
  that an operator might paste into Slack.

  ## Why a GenServer

  The GenServer is a single-process container for the plaintext. The
  alternative — a `defdelegate` to the `BotConfig` schema — would
  re-query the DB on every call and would lose the explicit
  "plaintext is held here" boundary. A single named GenServer makes
  the "no plaintext in env, no plaintext in DB result set" rule
  auditable: the only place plaintext lives is the GenServer's
  process state, and the only way to read it is the three accessor
  functions (`bot_token/0`, `secret_token/0`, `bot_username/0`).

  ## Fail-loud boot (REQ-C6-no-plaintext-in-env)

  If no `BotConfig` row exists for `Mix.env()`, `init/1` raises a
  clear, logged error. The operator is forced to bootstrap a row
  (via `BotConfig.upsert/1` or a seed) before the system accepts any
  Telegram traffic. This is the safe failure mode: a misconfigured
  deploy does not silently send `:unset` headers and the webhook
  plug does not silently compare against an empty string.

  ## Reload (REQ-C6-bot-token-gen-server-accessor)

  The `:reload` message re-reads the row from the DB. This is the
  rotation hook: an operator updates the row, sends `:reload` to the
  GenServer (or restarts the process), and the new plaintext is in
  effect immediately, without a deploy.

  ## Test contract

  The `stop/0` function is a test-only helper that stops the named
  GenServer if running and is a no-op otherwise. It is safe to call
  from test setup between tests to guarantee a clean state.
  """

  use GenServer

  alias Alethea.Foundation.Accounts.BotConfig

  @type plain :: %{bot_token: String.t(), secret_token: String.t(), bot_username: String.t()}

  ## Public API

  @doc """
  Starts the GenServer and registers it under `__MODULE__`.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Returns the plaintext bot token. Served from process state.
  """
  @spec bot_token() :: String.t()
  def bot_token, do: GenServer.call(__MODULE__, :bot_token)

  @doc """
  Returns the plaintext webhook secret token. Served from process state.
  """
  @spec secret_token() :: String.t()
  def secret_token, do: GenServer.call(__MODULE__, :secret_token)

  @doc """
  Returns the bot username. Served from process state.
  """
  @spec bot_username() :: String.t()
  def bot_username, do: GenServer.call(__MODULE__, :bot_username)

  @doc """
  Reloads the bot config from the DB. The next accessor call returns
  the new plaintext. Used for rotation without a deploy.
  """
  @spec reload() :: :ok
  def reload, do: GenServer.cast(__MODULE__, :reload)

  @doc """
  Test-only helper. Stops the GenServer if it is running. Returns
  `:ok` in both cases (running and not running). Safe to call from
  test setup.
  """
  @spec stop() :: :ok
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end

    :ok
  catch
    # F-06: `GenServer.stop/3` raises `:exit` (not an exception)
    # when the target process is already dead — `try/rescue` does
    # NOT catch `:exit` signals, only raised exceptions. We must use
    # `try/catch :exit, _` (or the equivalent `catch :exit, _` form)
    # to swallow the link/exit case. Pattern matches the
    # `pacer_test.exs:244-256` `safe_stop/0` helper, which already
    # has the same race condition.
    :exit, _ -> :ok
  end

  ## GenServer callbacks

  @impl true
  def init(_args) do
    case load() do
      {:ok, plain} ->
        {:ok, plain}

      {:error, reason} ->
        # Fail-loud: a missing row is a misconfiguration, not a default.
        # We log a clear error so the operator can see why the app failed
        # to boot, and we raise to keep the supervision tree honest.
        #
        # W-2 fix: never `inspect(reason)` — the whitelist match in
        # `reason_tag/1` guarantees we never leak a future `:unexpected`
        # payload (which could be a `%BotConfig{}` struct with
        # ciphertext blobs, ids, etc.) into the log.
        require Logger

        Logger.error(
          "Alethea.Telegram.BotToken failed to boot: " <>
            "no BotConfig row for env=#{Mix.env()} (reason: #{reason_tag(reason)}). " <>
            "Seed a row via Alethea.Foundation.Accounts.BotConfig.upsert/1 before starting the app."
        )

        raise "Alethea.Telegram.BotToken: no BotConfig row for env=#{Mix.env()}"
    end
  end

  @impl true
  def handle_call(:bot_token, _from, state), do: {:reply, state.bot_token, state}
  def handle_call(:secret_token, _from, state), do: {:reply, state.secret_token, state}
  def handle_call(:bot_username, _from, state), do: {:reply, state.bot_username, state}

  @impl true
  def handle_cast(:reload, _state), do: do_reload()

  @impl true
  def handle_info(:reload, _state), do: do_reload()

  # F-04: redact :bot_token and :secret_token from the human-readable
  # status returned by `:sys.get_state/1` and any other introspection
  # path that respects `format_status/1`. The state struct itself
  # still holds the plaintext (it has to — the GenServer is the
  # secret accessor); this callback is the layer that prevents the
  # plaintext from leaking into a log feed or a remote-console dump.
  # See `Alethea.Telegram.BotTokenTest "format_status/1 — redaction"`
  # for the contract.
  @impl true
  def format_status(_opt, [_pdict, state]) do
    redacted = %{
      bot_token: "[REDACTED]",
      secret_token: "[REDACTED]",
      bot_username: Map.get(state, :bot_username)
    }

    [data: redacted]
  end

  @doc """
  Maps a `load/0` failure reason to a safe, opaque log tag.

  W-2 fix: this is a WHITELIST match — never `inspect/1` — so the
  `init/1` and `do_reload/0` `Logger.error` calls never leak a future
  `:unexpected` payload (which could be a `%BotConfig{}` struct with
  ciphertext blobs, ids, etc.) into the operator's log feed. Today the
  only realistic reasons are `:not_found` (the row is gone) and
  `{:unexpected, other}` (the loaded struct did not match the guard).
  Both are mapped to a safe tag; any other term is mapped to `"other"`.
  """
  @spec reason_tag(term()) :: String.t()
  def reason_tag(:not_found), do: ":not_found"
  def reason_tag({:unexpected, _}), do: ":unexpected"
  def reason_tag(_), do: "other"

  ## Private

  # W-1 fix + S-4 cleanup: both `handle_cast(:reload, _)` and
  # `handle_info(:reload, _)` are wired to the same `do_reload/0` so
  # the load + log-and-reset logic lives in exactly one place.
  # The two callbacks exist so operators can use either
  # `GenServer.cast/2` (the public `BotToken.reload/0` API) or
  # `send/2` (a shell SIGHUP-style nudge) — both paths share the
  # same handler.
  @spec do_reload() ::
          {:noreply, plain() | %{bot_token: nil, secret_token: nil, bot_username: nil}}
  defp do_reload do
    case load() do
      {:ok, plain} -> {:noreply, plain}
      {:error, reason} -> log_and_reset(reason)
    end
  end

  @spec load() :: {:ok, plain()} | {:error, :not_found | term()}
  defp load do
    case BotConfig.for_env(to_string(Mix.env())) do
      {:ok, %BotConfig{bot_token: t, secret_token: s, bot_username: u}}
      when is_binary(t) and is_binary(s) and is_binary(u) ->
        {:ok, %{bot_token: t, secret_token: s, bot_username: u}}

      :not_found ->
        {:error, :not_found}

      other ->
        {:error, {:unexpected, other}}
    end
  end

  # W-1 fix: a reload that fails (e.g. the row was deleted while the
  # GenServer was running) used to silently reset state to nil with no
  # log. That made production webhooks 401 with no operator visibility.
  # We now log a clear error so the operator can re-seed the row and call
  # :reload again, while still failing closed (state reset to nil) so
  # the system never sends traffic with stale credentials.
  #
  # The reason tag in the log uses `reason_tag/1` — a WHITELIST match,
  # never `inspect(reason)` — so we never leak a future `:unexpected`
  # payload into the logs.
  @spec log_and_reset(term()) ::
          {:noreply, %{bot_token: nil, secret_token: nil, bot_username: nil}}
  defp log_and_reset(reason) do
    require Logger

    Logger.error(
      "Alethea.Telegram.BotToken reload failed: " <>
        "no BotConfig row for env=#{Mix.env()} (reason: #{reason_tag(reason)}). " <>
        "Re-seed the row via Alethea.Foundation.Accounts.BotConfig.upsert/1 and send :reload again. " <>
        "Failing closed: bot_token/0 now returns nil until the row is restored."
    )

    {:noreply, %{bot_token: nil, secret_token: nil, bot_username: nil}}
  end
end
