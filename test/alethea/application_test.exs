defmodule Alethea.ApplicationTest do
  @moduledoc """
  The shape of the supervision tree per configuration (issue #402): the
  Telegram Fake is supervised only when it is the configured adapter, and the
  sealed bot configuration loads before anything that can serve or send
  Telegram traffic.
  """

  use ExUnit.Case, async: false

  alias Alethea.Telegram.BotToken
  alias Alethea.Telegram.Client.Fake
  alias Alethea.Telegram.Pacer

  @keys [:start_bot_token, :start_telegram_pacer, :start_ai, :telegram_client]

  setup do
    previous = Map.new(@keys, &{&1, Application.fetch_env(:alethea, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:alethea, key, value)
        {key, :error} -> Application.delete_env(:alethea, key)
      end)
    end)
  end

  describe "production configuration" do
    setup do
      # What `config/config.exs` leaves a production build with.
      configure(
        start_bot_token: true,
        start_telegram_pacer: true,
        start_ai: true,
        telegram_client: Alethea.Telegram.Client.Req
      )
    end

    test "does not supervise the Telegram Fake" do
      refute Fake in child_modules()
      assert Pacer in child_modules()
    end

    test "loads the bot configuration after the repo and the vault it reads through" do
      modules = child_modules()

      assert position(modules, Alethea.Repo) < position(modules, BotToken)
      assert position(modules, Alethea.Encryption.Vault) < position(modules, BotToken)
    end

    test "loads the bot configuration before Oban and the endpoint" do
      modules = child_modules()

      assert position(modules, BotToken) < position(modules, Oban)
      assert position(modules, BotToken) < position(modules, AletheaWeb.Endpoint)
    end
  end

  describe "development configuration" do
    test "supervises the Fake when it is the configured adapter" do
      configure(start_telegram_pacer: true, telegram_client: Fake)

      assert Fake in child_modules()
      assert position(child_modules(), Pacer) < position(child_modules(), Fake)
    end

    test "supervises the Fake when no adapter is configured, as the workers fall back to it" do
      configure(start_telegram_pacer: true)
      Application.delete_env(:alethea, :telegram_client)

      assert Fake in child_modules()
    end

    test "does not supervise the Fake when the real client is selected" do
      configure(start_telegram_pacer: true, telegram_client: Alethea.Telegram.Client.Req)

      refute Fake in child_modules()
    end
  end

  describe "test configuration" do
    test "is unchanged: no supervised BotToken, Pacer or Fake" do
      modules = child_modules()

      refute BotToken in modules
      refute Pacer in modules
      refute Fake in modules

      assert Enum.take(modules, 5) == [
               AletheaWeb.Telemetry,
               Alethea.Repo,
               DNSCluster,
               Phoenix.PubSub,
               Alethea.Encryption.Vault
             ]

      assert position(modules, Oban) < position(modules, AletheaWeb.Endpoint)
    end

    test "the running tree matches the declared children" do
      running =
        Alethea.Supervisor
        |> Supervisor.which_children()
        |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

      refute Fake in running
      refute BotToken in running
      assert AletheaWeb.Endpoint in running
    end
  end

  defp configure(settings) do
    Enum.each(settings, fn {key, value} -> Application.put_env(:alethea, key, value) end)
  end

  defp child_modules do
    Enum.map(Alethea.Application.children(), fn
      {module, _arg} -> module
      module when is_atom(module) -> module
    end)
  end

  defp position(modules, module) do
    index = Enum.find_index(modules, &(&1 == module))
    assert is_integer(index), "#{inspect(module)} is not a supervised child"
    index
  end
end
