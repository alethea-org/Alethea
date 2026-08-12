defmodule Alethea.Foundation.Accounts.TelegramInviteTest do
  use Alethea.DataCase, async: true

  import Alethea.FoundationTestHelper

  alias Alethea.Foundation.Accounts
  alias Alethea.Foundation.Accounts.{BotConfig, PatientAuthCode}
  alias Alethea.Foundation.Accounts.Patient, as: FoundationPatient
  alias Alethea.Telegram.ChatIdHash

  # Deterministic 32-byte HMAC pepper (same convention as the
  # `lookup_patient_by_chat_hash` tests — the app itself does not
  # configure a pepper in the test env).
  @pepper "pepper-v1-32-bytes-min-len-padding-pad"

  describe "professional_by_email/1" do
    test "returns {:ok, professional} for a known foundation email" do
      professional = professional_fixture()

      assert {:ok, %Alethea.Foundation.Accounts.Professional{id: id}} =
               Accounts.professional_by_email(professional.email)

      assert id == professional.id
    end

    test "returns :not_found for an unknown email" do
      email = "nobody-#{System.unique_integer([:positive])}@example.com"

      assert Accounts.professional_by_email(email) == :not_found
    end
  end

  describe "invite_patient_to_telegram/2" do
    test "first invite: one bridged foundation row (alias mirrored) + deep_link and six_digit minted (~600s TTL)" do
      legacy_pro = legacy_professional_fixture()
      foundation_pro = professional_fixture(%{email: legacy_pro.email})
      legacy_patient = legacy_patient_fixture(legacy_pro)

      assert {:ok, invite} =
               Accounts.invite_patient_to_telegram(legacy_patient.id, foundation_pro)

      assert %{
               deep_link_token: deep_link_token,
               six_digit_code: six_digit_code,
               expires_at: expires_at,
               foundation_patient: %FoundationPatient{} = foundation_patient
             } = invite

      # Exactly one bridged foundation row; alias mirrored; scoped to the foundation pro.
      assert foundation_patient.alias == legacy_patient.alias
      assert foundation_patient.legacy_patient_id == legacy_patient.id
      assert foundation_patient.professional_id == foundation_pro.id

      assert Repo.aggregate(
               from(f in FoundationPatient, where: f.legacy_patient_id == ^legacy_patient.id),
               :count
             ) == 1

      # Both kinds minted against the foundation patient with the 10-minute TTL.
      deep_link = Repo.get_by!(PatientAuthCode, code: deep_link_token, kind: "deep_link")
      six_digit = Repo.get_by!(PatientAuthCode, code: six_digit_code, kind: "six_digit")

      assert deep_link.patient_id == foundation_patient.id
      assert six_digit.patient_id == foundation_patient.id
      assert deep_link.expires_at == expires_at
      assert DateTime.diff(deep_link.expires_at, DateTime.utc_now(), :second) in 590..600
      assert DateTime.diff(six_digit.expires_at, DateTime.utc_now(), :second) in 590..600
      assert Regex.match?(~r/^\d{6}$/, six_digit_code)
    end

    test "repeated call is idempotent: no new foundation row, both kinds re-minted" do
      legacy_pro = legacy_professional_fixture()
      foundation_pro = professional_fixture(%{email: legacy_pro.email})
      legacy_patient = legacy_patient_fixture(legacy_pro)

      assert {:ok, first} = Accounts.invite_patient_to_telegram(legacy_patient.id, foundation_pro)

      assert {:ok, second} =
               Accounts.invite_patient_to_telegram(legacy_patient.id, foundation_pro)

      assert first.foundation_patient.id == second.foundation_patient.id

      assert Repo.aggregate(
               from(f in FoundationPatient, where: f.legacy_patient_id == ^legacy_patient.id),
               :count
             ) == 1

      # Two mints per call (deep_link + six_digit), all against the same foundation row.
      assert Repo.aggregate(
               from(a in PatientAuthCode, where: a.patient_id == ^first.foundation_patient.id),
               :count
             ) == 4

      # A fresh deep-link token is returned each time (32 CSPRNG bytes).
      refute first.deep_link_token == second.deep_link_token
    end

    test "dangling legacy id: {:error, :legacy_not_found} and nothing minted" do
      legacy_pro = legacy_professional_fixture()
      foundation_pro = professional_fixture(%{email: legacy_pro.email})

      assert {:error, :legacy_not_found} =
               Accounts.invite_patient_to_telegram(Ecto.UUID.generate(), foundation_pro)

      assert Repo.aggregate(FoundationPatient, :count) == 0
      assert Repo.aggregate(PatientAuthCode, :count) == 0
    end

    test "foundation professional with no legacy counterpart: {:error, :legacy_not_found}" do
      # Unique email — no legacy professional row exists to bridge through.
      foundation_pro = professional_fixture()

      assert {:error, :legacy_not_found} =
               Accounts.invite_patient_to_telegram(Ecto.UUID.generate(), foundation_pro)

      assert Repo.aggregate(FoundationPatient, :count) == 0
      assert Repo.aggregate(PatientAuthCode, :count) == 0
    end

    test "cross-tenant isolation: professional B cannot invite professional A's patient" do
      legacy_pro_a = legacy_professional_fixture()
      legacy_patient_a = legacy_patient_fixture(legacy_pro_a)

      legacy_pro_b = legacy_professional_fixture()
      foundation_pro_b = professional_fixture(%{email: legacy_pro_b.email})

      assert {:error, :legacy_not_found} =
               Accounts.invite_patient_to_telegram(legacy_patient_a.id, foundation_pro_b)

      # Nothing minted and no foundation row bridged to A's patient.
      assert Repo.aggregate(PatientAuthCode, :count) == 0

      assert Repo.aggregate(
               from(f in FoundationPatient, where: f.legacy_patient_id == ^legacy_patient_a.id),
               :count
             ) == 0
    end
  end

  describe "telegram_connection_status/2" do
    test "returns :not_connected when no foundation row exists yet" do
      legacy_pro = legacy_professional_fixture()
      foundation_pro = professional_fixture(%{email: legacy_pro.email})
      legacy_patient = legacy_patient_fixture(legacy_pro)

      assert Accounts.telegram_connection_status(legacy_patient.id, foundation_pro) ==
               :not_connected
    end

    test "returns :not_connected when the scoped foundation row has no telegram_chat_id_hash" do
      legacy_pro = legacy_professional_fixture()
      foundation_pro = professional_fixture(%{email: legacy_pro.email})
      legacy_patient = legacy_patient_fixture(legacy_pro)

      assert {:ok, _} = Accounts.invite_patient_to_telegram(legacy_patient.id, foundation_pro)

      assert Accounts.telegram_connection_status(legacy_patient.id, foundation_pro) ==
               :not_connected
    end

    test "returns :connected after the /start bind flow binds the chat (hash present)" do
      legacy_pro = legacy_professional_fixture()
      foundation_pro = professional_fixture(%{email: legacy_pro.email})
      legacy_patient = legacy_patient_fixture(legacy_pro)

      assert {:ok, %{deep_link_token: token}} =
               Accounts.invite_patient_to_telegram(legacy_patient.id, foundation_pro)

      hash = ChatIdHash.hash(123_456_789, @pepper)

      assert {:ok, %FoundationPatient{}} =
               Accounts.consume_patient_auth_code(token, hash, kind: "deep_link")

      assert Accounts.telegram_connection_status(legacy_patient.id, foundation_pro) == :connected
    end

    test "returns {:error, :legacy_not_found} for a dangling legacy id" do
      legacy_pro = legacy_professional_fixture()
      foundation_pro = professional_fixture(%{email: legacy_pro.email})

      assert Accounts.telegram_connection_status(Ecto.UUID.generate(), foundation_pro) ==
               {:error, :legacy_not_found}
    end

    test "cross-tenant isolation: professional B sees no data for professional A's patient" do
      legacy_pro_a = legacy_professional_fixture()
      foundation_pro_a = professional_fixture(%{email: legacy_pro_a.email})
      legacy_patient_a = legacy_patient_fixture(legacy_pro_a)

      # Bind A's patient so a connected row exists under A's scope.
      assert {:ok, %{deep_link_token: token}} =
               Accounts.invite_patient_to_telegram(legacy_patient_a.id, foundation_pro_a)

      assert {:ok, _} =
               Accounts.consume_patient_auth_code(
                 token,
                 ChatIdHash.hash(987_654_321, @pepper),
                 kind: "deep_link"
               )

      legacy_pro_b = legacy_professional_fixture()
      foundation_pro_b = professional_fixture(%{email: legacy_pro_b.email})

      assert Accounts.telegram_connection_status(legacy_patient_a.id, foundation_pro_b) ==
               {:error, :legacy_not_found}
    end
  end

  describe "telegram_connection_statuses/2" do
    test "maps each legacy id to its status: connected / invited-not-connected / untouched" do
      legacy_pro = legacy_professional_fixture()
      foundation_pro = professional_fixture(%{email: legacy_pro.email})

      connected = legacy_patient_fixture(legacy_pro, %{alias: "Connected"})
      invited = legacy_patient_fixture(legacy_pro, %{alias: "Invited"})
      untouched = legacy_patient_fixture(legacy_pro, %{alias: "Untouched"})

      # Connected through the real bind flow.
      assert {:ok, %{deep_link_token: token}} =
               Accounts.invite_patient_to_telegram(connected.id, foundation_pro)

      assert {:ok, _} =
               Accounts.consume_patient_auth_code(
                 token,
                 ChatIdHash.hash(555_555_555, @pepper),
                 kind: "deep_link"
               )

      # Invited but not connected (foundation row, no hash).
      assert {:ok, _} = Accounts.invite_patient_to_telegram(invited.id, foundation_pro)

      ids = [connected.id, invited.id, untouched.id]

      connected_id = connected.id
      invited_id = invited.id
      untouched_id = untouched.id

      assert %{
               ^connected_id => :connected,
               ^invited_id => :not_connected,
               ^untouched_id => :not_connected
             } = Accounts.telegram_connection_statuses(ids, foundation_pro)
    end

    test "cross-tenant: ids outside the professional's scope map to :not_connected" do
      legacy_pro_a = legacy_professional_fixture()
      foundation_pro_a = professional_fixture(%{email: legacy_pro_a.email})
      connected_a = legacy_patient_fixture(legacy_pro_a)

      assert {:ok, %{deep_link_token: token}} =
               Accounts.invite_patient_to_telegram(connected_a.id, foundation_pro_a)

      assert {:ok, _} =
               Accounts.consume_patient_auth_code(
                 token,
                 ChatIdHash.hash(444_444_444, @pepper),
                 kind: "deep_link"
               )

      legacy_pro_b = legacy_professional_fixture()
      foundation_pro_b = professional_fixture(%{email: legacy_pro_b.email})

      # B must never observe A's connected status.
      connected_a_id = connected_a.id

      assert Accounts.telegram_connection_statuses([connected_a.id], foundation_pro_b) ==
               %{connected_a_id => :not_connected}
    end
  end

  describe "test support fixtures" do
    test "bot_config_fixture/0 upserts a usable test-env BotConfig row" do
      bot_config = bot_config_fixture()

      assert bot_config.env == "test"
      assert {:ok, %BotConfig{bot_username: "fixture_bot"}} = BotConfig.for_env("test")
    end
  end

  describe "hash-only storage (no contact PII)" do
    test "binding stores only the 64-hex HMAC, never the raw chat_id" do
      legacy_pro = legacy_professional_fixture()
      foundation_pro = professional_fixture(%{email: legacy_pro.email})
      legacy_patient = legacy_patient_fixture(legacy_pro)

      raw_chat_id = "987654321"

      assert {:ok, %{deep_link_token: token}} =
               Accounts.invite_patient_to_telegram(legacy_patient.id, foundation_pro)

      assert {:ok, %FoundationPatient{} = patient} =
               Accounts.consume_patient_auth_code(
                 token,
                 ChatIdHash.hash(raw_chat_id, @pepper),
                 kind: "deep_link"
               )

      persisted = Repo.get!(FoundationPatient, patient.id)

      assert persisted.telegram_chat_id_hash == ChatIdHash.hash(raw_chat_id, @pepper)
      assert Regex.match?(~r/^[0-9a-f]{64}$/, persisted.telegram_chat_id_hash)
      refute persisted.telegram_chat_id_hash == raw_chat_id
      refute inspect(persisted) =~ raw_chat_id

      # The raw chat_id is not a queryable value on the row.
      assert Repo.aggregate(
               from(f in FoundationPatient, where: f.telegram_chat_id_hash == ^raw_chat_id),
               :count
             ) == 0
    end
  end
end

defmodule Alethea.Foundation.Accounts.TelegramInviteBatchQueryCountTest do
  # Non-async so the telemetry query count is deterministic (no concurrent
  # test can emit ecto queries during the assertion).
  use Alethea.DataCase, async: false

  import Alethea.FoundationTestHelper

  alias Alethea.Foundation.Accounts
  alias Alethea.Foundation.Accounts.Patient, as: FoundationPatient
  alias Alethea.Telegram.ChatIdHash

  @pepper "pepper-v1-32-bytes-min-len-padding-pad"

  setup do
    legacy_pro = legacy_professional_fixture()
    foundation_pro = professional_fixture(%{email: legacy_pro.email})

    connected = legacy_patient_fixture(legacy_pro, %{alias: "Connected"})
    invited = legacy_patient_fixture(legacy_pro, %{alias: "Invited"})
    untouched = legacy_patient_fixture(legacy_pro, %{alias: "Untouched"})

    assert {:ok, %{deep_link_token: token}} =
             Accounts.invite_patient_to_telegram(connected.id, foundation_pro)

    assert {:ok, %FoundationPatient{}} =
             Accounts.consume_patient_auth_code(
               token,
               ChatIdHash.hash(333_333_333, @pepper),
               kind: "deep_link"
             )

    assert {:ok, _} = Accounts.invite_patient_to_telegram(invited.id, foundation_pro)

    ids = [connected.id, invited.id, untouched.id]

    {:ok,
     foundation_pro: foundation_pro,
     ids: ids,
     connected_id: connected.id,
     invited_id: invited.id,
     untouched_id: untouched.id}
  end

  test "telegram_connection_statuses/2 resolves N ids with a single query on foundation_patients",
       %{
         foundation_pro: foundation_pro,
         ids: ids,
         connected_id: connected_id,
         invited_id: invited_id,
         untouched_id: untouched_id
       } do
    handler_id = {__MODULE__, System.unique_integer([:positive])}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:alethea, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:query, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    statuses = Accounts.telegram_connection_statuses(ids, foundation_pro)

    assert %{
             ^connected_id => :connected,
             ^invited_id => :not_connected,
             ^untouched_id => :not_connected
           } = statuses

    [query] = collect_queries()
    sql = to_string(Map.fetch!(query, :query))
    assert sql =~ "foundation_patients"
  end

  defp collect_queries do
    receive do
      {:query, metadata} -> [metadata | collect_queries()]
    after
      0 -> []
    end
  end
end
