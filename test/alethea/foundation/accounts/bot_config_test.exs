defmodule Alethea.Foundation.Accounts.BotConfigTest do
  @moduledoc """
  Tests for `Alethea.Foundation.Accounts.BotConfig` (C-6 sealed bot token).

  Covers:
  - `REQ-C6-bot-token-stored-encrypted`: `token_ciphertext` and
    `secret_token_ciphertext` are `Cloak.Ecto.Binary` fields; the plaintext
    is never persisted as a column value, never round-tripped through the
    schema as plaintext, and the persisted value is unreadable without the
    Cloak key.
  - `REQ-C6-distinct-per-env`: only one row per env is allowed; the
    `env` field accepts `"dev" | "test" | "prod"` and rejects other values.
  - `for_env/1` returns the row for the given environment, or `nil` if
    none exists.
  - `upsert/1` creates the row if it does not exist, and updates the row
    in place if it does (no duplicate env).
  """

  use Alethea.DataCase, async: false

  alias Alethea.Foundation.Accounts.BotConfig
  alias Alethea.Repo

  @valid_attrs %{
    env: "prod",
    bot_token: "123456:ABC-DEF-PROD-TOKEN",
    secret_token: "prod-shared-secret",
    bot_username: "alethea_prod_bot"
  }

  describe "BotConfig schema — encrypted fields (REQ-C6-bot-token-stored-encrypted)" do
    test "plaintext bot_token can be read back via the schema (Cloak round-trip)" do
      {:ok, bot_config} = BotConfig.upsert(@valid_attrs)
      reloaded = Repo.get!(BotConfig, bot_config.id)

      # The schema's load/2 decrypts the ciphertext back to plaintext via Cloak.
      # This is the only path by which the plaintext is recoverable.
      assert reloaded.bot_token == "123456:ABC-DEF-PROD-TOKEN"
      assert reloaded.secret_token == "prod-shared-secret"
    end

    test "the bot_token field on the loaded struct is the plaintext, not the ciphertext" do
      {:ok, bot_config} = BotConfig.upsert(@valid_attrs)
      reloaded = Repo.get!(BotConfig, bot_config.id)

      # The :source option rebinds the field name to the on-disk column;
      # callers see the plaintext, never the ciphertext. The struct itself
      # does not expose the `token_ciphertext` field — only the logical
      # `bot_token` field is part of the struct.
      refute Map.has_key?(reloaded, :token_ciphertext)
      refute Map.has_key?(reloaded, :secret_token_ciphertext)
      assert is_binary(reloaded.bot_token)
      assert is_binary(reloaded.secret_token)
    end

    test "the raw database row stores ciphertext, not plaintext" do
      {:ok, bot_config} = BotConfig.upsert(@valid_attrs)

      # Query the encrypted columns directly via raw SQL. This bypasses the
      # schema's Cloak decoder and returns the raw AES-GCM ciphertext blobs.
      # The plaintext must NOT appear anywhere in the raw ciphertext.
      #
      # `Ecto.UUID.dump!/1` converts the string UUID to the 16-byte binary
      # representation that Postgrex expects for a `:binary_id` column
      # stored as `uuid`.
      uuid_binary = Ecto.UUID.dump!(bot_config.id)

      result =
        Ecto.Adapters.SQL.query!(
          Alethea.Repo,
          "SELECT token_ciphertext, secret_token_ciphertext FROM foundation_bot_configs WHERE id = $1",
          [uuid_binary]
        )

      [[token_blob, secret_blob]] = result.rows

      assert is_binary(token_blob)
      assert is_binary(secret_blob)
      # The plaintext must not be a substring of the raw ciphertext blob.
      # `:binary.match/2` returns `:nomatch` when the needle is absent.
      assert :binary.match(token_blob, "123456:ABC-DEF-PROD-TOKEN") == :nomatch
      assert :binary.match(secret_blob, "prod-shared-secret") == :nomatch
      # The raw blobs are non-trivially different from the plaintext (IV +
      # GCM tag add overhead, and the encrypted bytes do not match).
      assert byte_size(token_blob) > byte_size("123456:ABC-DEF-PROD-TOKEN")
      assert byte_size(secret_blob) > byte_size("prod-shared-secret")
    end
  end

  describe "BotConfig schema — env discriminator (REQ-C6-distinct-per-env)" do
    test "env accepts dev, test, prod" do
      for env <- ["dev", "test", "prod"] do
        attrs = Map.put(@valid_attrs, :env, env)
        assert {:ok, %BotConfig{env: ^env}} = BotConfig.upsert(attrs)
      end
    end

    test "env rejects values outside the canonical set" do
      attrs = Map.put(@valid_attrs, :env, "staging")
      assert {:error, %Ecto.Changeset{} = changeset} = BotConfig.upsert(attrs)
      assert %{env: [_ | _]} = errors_on(changeset)
    end

    test "a second upsert for the same env updates the row in place" do
      assert {:ok, %BotConfig{id: first_id}} = BotConfig.upsert(@valid_attrs)

      assert {:ok, %BotConfig{id: ^first_id, bot_username: "new_username"}} =
               BotConfig.upsert(%{@valid_attrs | bot_username: "new_username"})

      assert Repo.aggregate(BotConfig, :count) == 1
    end

    test "two different envs coexist as two rows" do
      assert {:ok, _} = BotConfig.upsert(Map.put(@valid_attrs, :env, "dev"))
      assert {:ok, _} = BotConfig.upsert(Map.put(@valid_attrs, :env, "prod"))

      assert Repo.aggregate(BotConfig, :count) == 2
    end
  end

  describe "for_env/1" do
    test "returns the row for the given env" do
      assert {:ok, %BotConfig{}} = BotConfig.upsert(@valid_attrs)

      assert {:ok, %BotConfig{env: "prod", bot_username: "alethea_prod_bot"}} =
               BotConfig.for_env("prod")
    end

    test "returns :not_found when no row exists for the env" do
      assert :not_found = BotConfig.for_env("nonexistent-env")
    end

    test "returns the correct row when multiple envs coexist" do
      assert {:ok, _} = BotConfig.upsert(Map.put(@valid_attrs, :env, "dev"))
      assert {:ok, _} = BotConfig.upsert(Map.put(@valid_attrs, :env, "prod"))

      assert {:ok, %BotConfig{env: "dev"}} = BotConfig.for_env("dev")
      assert {:ok, %BotConfig{env: "prod"}} = BotConfig.for_env("prod")
    end
  end

  describe "upsert/1 — validation" do
    test "rejects an empty bot_token" do
      attrs = %{@valid_attrs | bot_token: ""}
      assert {:error, %Ecto.Changeset{} = changeset} = BotConfig.upsert(attrs)
      assert %{bot_token: [_ | _]} = errors_on(changeset)
    end

    test "rejects an empty bot_username" do
      attrs = %{@valid_attrs | bot_username: ""}
      assert {:error, %Ecto.Changeset{} = changeset} = BotConfig.upsert(attrs)
      assert %{bot_username: [_ | _]} = errors_on(changeset)
    end

    test "rejects an empty secret_token" do
      attrs = %{@valid_attrs | secret_token: ""}
      assert {:error, %Ecto.Changeset{} = changeset} = BotConfig.upsert(attrs)
      assert %{secret_token: [_ | _]} = errors_on(changeset)
    end
  end
end
