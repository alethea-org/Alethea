defmodule Alethea.Telegram.BootstrapTest do
  @moduledoc """
  The release-callable Telegram bootstrap (issue #402): it writes the sealed
  `BotConfig` row from the three `TELEGRAM_*` variables, is idempotent, and
  never echoes a secret. Every value below is synthetic.
  """

  use Alethea.DataCase, async: false

  import ExUnit.CaptureLog

  alias Alethea.Foundation.Accounts.BotConfig
  alias Alethea.Repo
  alias Alethea.Telegram.Bootstrap

  @bot_token "123456:synthetic-bootstrap-token"
  @secret_token "synthetic_webhook_secret"
  @bot_username "alethea_synthetic_bot"

  @vars %{
    "TELEGRAM_BOT_TOKEN" => @bot_token,
    "TELEGRAM_WEBHOOK_SECRET" => @secret_token,
    "TELEGRAM_BOT_USERNAME" => @bot_username
  }

  setup do
    Repo.delete_all(BotConfig)
    :ok
  end

  describe "run/2" do
    test "creates the encrypted row for the environment" do
      assert {:ok, %{status: :created, env: "test", bot_username: @bot_username}} =
               Bootstrap.run("test", @vars)

      assert {:ok,
              %BotConfig{
                bot_token: @bot_token,
                secret_token: @secret_token,
                bot_username: @bot_username
              }} = BotConfig.for_env("test")
    end

    test "stores ciphertext, never the plaintext token or secret" do
      assert {:ok, %{status: :created}} = Bootstrap.run("test", @vars)

      %{rows: [[token_ciphertext, secret_ciphertext]]} =
        Repo.query!(
          "SELECT token_ciphertext, secret_token_ciphertext FROM foundation_bot_configs WHERE env = 'test'"
        )

      refute token_ciphertext =~ @bot_token
      refute secret_ciphertext =~ @secret_token
    end

    test "running twice with the same values leaves one untouched row" do
      assert {:ok, %{status: :created}} = Bootstrap.run("test", @vars)
      {:ok, %BotConfig{id: id, updated_at: updated_at}} = BotConfig.for_env("test")

      assert {:ok, %{status: :unchanged, env: "test", bot_username: @bot_username}} =
               Bootstrap.run("test", @vars)

      assert Repo.aggregate(BotConfig, :count) == 1
      assert {:ok, %BotConfig{id: ^id, updated_at: ^updated_at}} = BotConfig.for_env("test")
    end

    test "rotates the token, the secret and the username in place" do
      assert {:ok, %{status: :created}} = Bootstrap.run("test", @vars)

      rotated = %{
        "TELEGRAM_BOT_TOKEN" => "654321:synthetic-rotated-token",
        "TELEGRAM_WEBHOOK_SECRET" => "synthetic-rotated-secret",
        "TELEGRAM_BOT_USERNAME" => "@alethea_rotated_bot"
      }

      assert {:ok, %{status: :updated, bot_username: "alethea_rotated_bot"}} =
               Bootstrap.run("test", rotated)

      assert Repo.aggregate(BotConfig, :count) == 1

      assert {:ok,
              %BotConfig{
                bot_token: "654321:synthetic-rotated-token",
                secret_token: "synthetic-rotated-secret",
                bot_username: "alethea_rotated_bot"
              }} = BotConfig.for_env("test")
    end

    test "trims surrounding whitespace and a leading @ before storing" do
      vars = %{
        "TELEGRAM_BOT_TOKEN" => "  #{@bot_token}\n",
        "TELEGRAM_WEBHOOK_SECRET" => " #{@secret_token} ",
        "TELEGRAM_BOT_USERNAME" => "@#{@bot_username}"
      }

      assert {:ok, %{status: :created, bot_username: @bot_username}} = Bootstrap.run("test", vars)
      assert {:ok, %{status: :unchanged}} = Bootstrap.run("test", @vars)
    end

    test "rejects a missing or blank variable without writing" do
      for name <- Map.keys(@vars), value <- [nil, "", "   "] do
        vars = if value, do: Map.put(@vars, name, value), else: Map.delete(@vars, name)

        assert Bootstrap.run("test", vars) == {:error, {:missing, name}}
      end

      assert Repo.aggregate(BotConfig, :count) == 0
    end

    test "rejects malformed values without writing" do
      invalid = [
        {"TELEGRAM_BOT_TOKEN", "no-colon-synthetic-token"},
        {"TELEGRAM_BOT_TOKEN", "abc:synthetic-token"},
        {"TELEGRAM_BOT_TOKEN", "123456:synthetic token"},
        {"TELEGRAM_BOT_TOKEN", "123456:"},
        {"TELEGRAM_WEBHOOK_SECRET", "synthetic secret"},
        {"TELEGRAM_WEBHOOK_SECRET", "synthetic.secret"},
        {"TELEGRAM_WEBHOOK_SECRET", String.duplicate("s", 257)},
        {"TELEGRAM_BOT_USERNAME", "abc"},
        {"TELEGRAM_BOT_USERNAME", "synthetic-bot"},
        {"TELEGRAM_BOT_USERNAME", String.duplicate("b", 33)}
      ]

      for {name, value} <- invalid do
        assert Bootstrap.run("test", Map.put(@vars, name, value)) == {:error, {:invalid, name}}
      end

      assert Repo.aggregate(BotConfig, :count) == 0
    end

    test "accepts the longest secret Telegram allows" do
      secret = String.duplicate("s", 256)

      assert {:ok, %{status: :created}} =
               Bootstrap.run("test", Map.put(@vars, "TELEGRAM_WEBHOOK_SECRET", secret))
    end

    test "rejects an unknown environment without writing" do
      assert Bootstrap.run("staging", @vars) == {:error, :invalid_env}
      assert Repo.aggregate(BotConfig, :count) == 0
    end
  end

  describe "secrets hygiene" do
    setup do
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)
    end

    test "no result, message or log line carries the token or the secret" do
      {results, log} =
        with_log(fn ->
          [
            Bootstrap.run("test", @vars),
            Bootstrap.run("test", @vars),
            Bootstrap.run(
              "test",
              Map.put(@vars, "TELEGRAM_WEBHOOK_SECRET", "rotated_secret_value")
            ),
            Bootstrap.run("test", Map.put(@vars, "TELEGRAM_BOT_USERNAME", "alethea_other_bot")),
            Bootstrap.run("test", Map.put(@vars, "TELEGRAM_BOT_TOKEN", "#{@bot_token} broken")),
            Bootstrap.run("test", Map.put(@vars, "TELEGRAM_WEBHOOK_SECRET", "#{@secret_token}!"))
          ]
        end)

      assert [
               {:ok, %{status: :created}},
               {:ok, %{status: :unchanged}},
               {:ok, %{status: :updated}},
               {:ok, %{status: :updated}},
               {:error, {:invalid, "TELEGRAM_BOT_TOKEN"}},
               {:error, {:invalid, "TELEGRAM_WEBHOOK_SECRET"}}
             ] = results

      # The level is :debug here, so the read of the row is in the log; the
      # write, whose parameters are the plaintext, must not be.
      assert Logger.get_process_level(self()) == nil

      messages =
        for {:error, reason} <- results, do: Bootstrap.message(reason)

      rendered = inspect(results, limit: :infinity, printable_limit: :infinity)

      for text <- [rendered, log | messages] do
        refute text =~ @bot_token
        refute text =~ @secret_token
        refute text =~ "rotated_secret_value"
      end
    end

    test "every failure maps to a fixed message" do
      assert Bootstrap.message({:missing, "TELEGRAM_BOT_TOKEN"}) ==
               "TELEGRAM_BOT_TOKEN is required"

      assert Bootstrap.message({:invalid, "TELEGRAM_WEBHOOK_SECRET"}) ==
               "TELEGRAM_WEBHOOK_SECRET must contain 1 to 256 letters, digits, underscores, or hyphens"

      assert Bootstrap.message({:invalid, "TELEGRAM_BOT_USERNAME"}) ==
               "TELEGRAM_BOT_USERNAME must contain 5 to 32 letters, digits, or underscores"

      assert Bootstrap.message({:invalid, "TELEGRAM_BOT_TOKEN"}) =~ "TELEGRAM_BOT_TOKEN must"
      assert Bootstrap.message(:invalid_env) =~ "dev, test or prod"
      assert Bootstrap.message(:write_failed) =~ "could not be written"

      assert Bootstrap.message({:database_error, DBConnection.ConnectionError}) ==
               "Telegram bot configuration could not be written (DBConnection.ConnectionError)"
    end
  end
end
