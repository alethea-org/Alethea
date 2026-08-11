defmodule Alethea.Foundation.AccountsTest do
  use Alethea.DataCase, async: true

  alias Alethea.Accounts, as: Legacy
  alias Alethea.Foundation.Accounts

  describe "register_professional/1" do
    test "delegates to the Professional schema and returns a persisted row" do
      attrs = %{
        email: "ctx-pro-#{System.unique_integer([:positive])}@example.com",
        password: "supersecret12",
        full_name: "Ctx Pro"
      }

      assert {:ok, %Alethea.Foundation.Accounts.Professional{} = pro} =
               Accounts.register_professional(attrs)

      assert pro.email == attrs.email
      assert is_binary(pro.password_hash)
    end
  end

  describe "create_patient/2 + update_patient/2" do
    test "delegates create_patient/2 to the Patient schema and update_patient/2 mutates" do
      pro = Alethea.FoundationTestHelper.professional_fixture()

      assert {:ok, %Alethea.Foundation.Accounts.Patient{} = patient} =
               Accounts.create_patient(pro, %{alias: "Ctx Pat"})

      assert patient.professional_id == pro.id

      assert {:ok, %Alethea.Foundation.Accounts.Patient{} = updated} =
               Accounts.update_patient(patient, %{status: "archived"})

      assert updated.status == "archived"
    end
  end

  describe "register_admin/1" do
    test "delegates to the Admin schema and returns a persisted row" do
      attrs = %{
        email: "ctx-admin-#{System.unique_integer([:positive])}@alethea.app",
        password: "supersecret12",
        role: "billing"
      }

      assert {:ok, %Alethea.Foundation.Accounts.Admin{} = admin} =
               Accounts.register_admin(attrs)

      assert admin.role == "billing"
    end
  end

  describe "find_or_provision_foundation_professional/1 — bridge from the legacy row (decision #111, Option A)" do
    test "creates a foundation professional on the first call" do
      {:ok, legacy} = create_legacy_professional()

      assert {:ok, %Alethea.Foundation.Accounts.Professional{} = foundation} =
               Accounts.find_or_provision_foundation_professional(legacy)

      assert foundation.email == legacy.email
      assert foundation.full_name == legacy.full_name
      assert foundation.legacy_professional_id == legacy.id
      assert is_binary(foundation.password_hash)
    end

    test "is idempotent — a second call returns the same foundation row, no duplicate" do
      {:ok, legacy} = create_legacy_professional()

      assert {:ok, %Alethea.Foundation.Accounts.Professional{} = first} =
               Accounts.find_or_provision_foundation_professional(legacy)

      assert {:ok, %Alethea.Foundation.Accounts.Professional{} = second} =
               Accounts.find_or_provision_foundation_professional(legacy)

      assert first.id == second.id
      assert first.password_hash == second.password_hash
    end

    test "different legacy professionals get distinct foundation rows" do
      {:ok, legacy_a} = create_legacy_professional("a")
      {:ok, legacy_b} = create_legacy_professional("b")

      assert {:ok, %Alethea.Foundation.Accounts.Professional{} = foundation_a} =
               Accounts.find_or_provision_foundation_professional(legacy_a)

      assert {:ok, %Alethea.Foundation.Accounts.Professional{} = foundation_b} =
               Accounts.find_or_provision_foundation_professional(legacy_b)

      refute foundation_a.id == foundation_b.id
      assert foundation_a.legacy_professional_id == legacy_a.id
      assert foundation_b.legacy_professional_id == legacy_b.id
    end

    test "the copied hash validates via Pbkdf2.verify_pass against the legacy password" do
      password = "supersecret12"
      {:ok, legacy} = create_legacy_professional_with_password(password)

      assert {:ok, %Alethea.Foundation.Accounts.Professional{} = foundation} =
               Accounts.find_or_provision_foundation_professional(legacy)

      assert Pbkdf2.verify_pass(password, foundation.password_hash)
      refute Pbkdf2.verify_pass("not-the-password", foundation.password_hash)
    end

    test "returns the existing row when the foundation side is already provisioned" do
      # If a foundation row was provisioned out-of-band (e.g. by the
      # bootstrap mix task that mirrors every legacy row), the helper
      # must NOT re-insert — it must look up and return the existing
      # one. This is the "lookup-first" half of the race-safety design.
      {:ok, legacy} = create_legacy_professional()

      # Pre-provision out-of-band via the schema.
      {:ok, pre_existing} =
        Alethea.Foundation.Accounts.Professional.provision_foundation_professional(legacy)

      # Now the helper should find this row, not create a new one.
      assert {:ok, %Alethea.Foundation.Accounts.Professional{} = foundation} =
               Accounts.find_or_provision_foundation_professional(legacy)

      assert foundation.id == pre_existing.id
    end

    test "rejects a legacy professional with missing required fields" do
      # Defensive: a legacy row with no email / full_name / password_hash
      # should not silently leak through. The schema's validate_required
      # surfaces a changeset error.
      broken_legacy = %Legacy.Professional{
        id: Ecto.UUID.generate(),
        email: nil,
        full_name: nil,
        password_hash: nil
      }

      assert {:error, %Ecto.Changeset{} = changeset} =
               Accounts.find_or_provision_foundation_professional(broken_legacy)

      assert %{email: [_ | _]} = errors_on(changeset)
    end
  end

  describe "public API surface" do
    test "exports the canonical functions" do
      exported = Accounts.__info__(:functions)

      assert {:register_professional, 1} in exported
      assert {:register_admin, 1} in exported
      assert {:create_patient, 2} in exported
      assert {:update_patient, 2} in exported
      assert {:lookup_patient_by_chat_hash, 1} in exported
      assert {:find_or_provision_foundation_professional, 1} in exported
    end
  end

  describe "lookup_patient_by_chat_hash/1 — REQ-C2-lookup-by-hash" do
    test "returns {:ok, patient} for a patient bound to a known hash" do
      pro = Alethea.FoundationTestHelper.professional_fixture()
      hash = valid_hash_for(42)

      {:ok, patient} =
        Accounts.create_patient(pro, %{alias: "Bound", telegram_chat_id_hash: hash})

      assert {:ok, %Alethea.Foundation.Accounts.Patient{id: id}} =
               Accounts.lookup_patient_by_chat_hash(hash)

      assert id == patient.id
    end

    test "returns :not_found for an unknown hash" do
      assert Accounts.lookup_patient_by_chat_hash(unbound_hash()) == :not_found
    end

    test "returns :not_found for a raw chat_id (rejected at the API boundary)" do
      # REQ-C2-lookup-by-hash: the function accepts only the 64-char
      # hex hash form. A raw chat_id integer-as-string (9 chars) is
      # not a valid hash, so the function must not return a false
      # positive by hashing on the caller side.
      assert Accounts.lookup_patient_by_chat_hash("123456789") == :not_found
    end

    test "returns :not_found for non-hex garbage (also not a 64-char hash)" do
      # 64 chars but not lowercase hex
      assert Accounts.lookup_patient_by_chat_hash(String.duplicate("Z", 64)) == :not_found
    end
  end

  describe "lookup_patient_by_chat_hash/1 — REQ-C2-partial-unique-index" do
    test "two patients bound to the same hash: the second insert fails at the DB layer" do
      pro = Alethea.FoundationTestHelper.professional_fixture()
      hash = valid_hash_for(99)

      assert {:ok, %Alethea.Foundation.Accounts.Patient{}} =
               Accounts.create_patient(pro, %{alias: "First", telegram_chat_id_hash: hash})

      assert {:error, %Ecto.Changeset{}} =
               Accounts.create_patient(pro, %{alias: "Second", telegram_chat_id_hash: hash})
    end

    test "multiple patients with NULL telegram_chat_id_hash coexist" do
      pro = Alethea.FoundationTestHelper.professional_fixture()

      assert {:ok, %Alethea.Foundation.Accounts.Patient{}} =
               Accounts.create_patient(pro, %{alias: "P1"})

      assert {:ok, %Alethea.Foundation.Accounts.Patient{}} =
               Accounts.create_patient(pro, %{alias: "P2"})

      assert {:ok, %Alethea.Foundation.Accounts.Patient{}} =
               Accounts.create_patient(pro, %{alias: "P3"})
    end
  end

  describe "invite_to_telegram/2 — #108" do
    setup do
      legacy_pro = legacy_professional_fixture()

      kek =
        case Alethea.Accounts.load_professional_kek(legacy_pro) do
          {:ok, kek} -> kek
          _ -> Alethea.Encryption.ProfessionalKek.generate_kek()
        end

      legacy_pat =
        legacy_patient_fixture(legacy_pro,
          alias: "Invitee #{System.unique_integer([:positive])}",
          kek_bytes: kek
        )

      %{legacy_pro: legacy_pro, legacy_pat: legacy_pat}
    end

    test "provisions a foundation Patient bridged by legacy_patient_id", %{
      legacy_pro: legacy_pro,
      legacy_pat: legacy_pat
    } do
      assert {:ok, invite} = Accounts.invite_to_telegram(legacy_pat, legacy_pro)

      foundation = invite.patient
      assert %Alethea.Foundation.Accounts.Patient{} = foundation
      assert foundation.legacy_patient_id == legacy_pat.id
      assert foundation.professional_id == legacy_pro.id
      assert foundation.alias == legacy_pat.alias
    end

    test "returns both invite kinds (deep_link + six_digit)", %{
      legacy_pro: legacy_pro,
      legacy_pat: legacy_pat
    } do
      assert {:ok, invite} = Accounts.invite_to_telegram(legacy_pat, legacy_pro)

      # 32 raw bytes URL-safe base64 (no padding) → exactly 43 chars
      assert byte_size(invite.deep_link) == 43
      assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, invite.deep_link)

      assert String.length(invite.six_digit) == 6
      assert Regex.match?(~r/^[0-9]{6}$/, invite.six_digit)
    end

    test "expires_at is ~10 minutes after mint", %{
      legacy_pro: legacy_pro,
      legacy_pat: legacy_pat
    } do
      assert {:ok, invite} = Accounts.invite_to_telegram(legacy_pat, legacy_pro)

      delta = DateTime.diff(invite.expires_at, DateTime.utc_now(), :second)
      assert_in_delta delta, 600, 2
    end

    test "is idempotent per patient — a second call reuses the same foundation row", %{
      legacy_pro: legacy_pro,
      legacy_pat: legacy_pat
    } do
      assert {:ok, first} = Accounts.invite_to_telegram(legacy_pat, legacy_pro)
      assert {:ok, second} = Accounts.invite_to_telegram(legacy_pat, legacy_pro)

      assert first.patient.id == second.patient.id

      # Foundation count for this bridge is exactly 1 — no duplicate
      # identity row was minted on the second call.
      count =
        Alethea.Foundation.Accounts.Patient
        |> where([p], p.legacy_patient_id == ^legacy_pat.id)
        |> Alethea.Repo.aggregate(:count)

      assert count == 1

      # Each call mints a fresh code (the underlying auth-code TTL is
      # the rotation boundary), so the codes differ.
      assert first.deep_link != second.deep_link
      assert first.six_digit != second.six_digit
    end

    test "is scoped to the acting professional — cross-tenant calls fail closed", %{
      legacy_pat: legacy_pat
    } do
      other_pro = legacy_professional_fixture()

      assert {:error, :tenant_mismatch} =
               Accounts.invite_to_telegram(legacy_pat, other_pro)

      # And no foundation row was minted for the cross-tenant probe.
      count =
        Alethea.Foundation.Accounts.Patient
        |> where([p], p.legacy_patient_id == ^legacy_pat.id)
        |> Alethea.Repo.aggregate(:count)

      assert count == 0
    end
  end

  describe "telegram_connected?/1 — #108" do
    setup do
      legacy_pro = legacy_professional_fixture()

      kek =
        case Alethea.Accounts.load_professional_kek(legacy_pro) do
          {:ok, kek} -> kek
          _ -> Alethea.Encryption.ProfessionalKek.generate_kek()
        end

      legacy_pat =
        legacy_patient_fixture(legacy_pro,
          alias: "Conn #{System.unique_integer([:positive])}",
          kek_bytes: kek
        )

      %{legacy_pro: legacy_pro, legacy_pat: legacy_pat}
    end

    test "returns false before any invite is minted", %{legacy_pat: legacy_pat} do
      refute Accounts.telegram_connected?(legacy_pat)
    end

    test "returns false after invite is minted — the patient has not yet /started", %{
      legacy_pro: legacy_pro,
      legacy_pat: legacy_pat
    } do
      {:ok, _invite} = Accounts.invite_to_telegram(legacy_pat, legacy_pro)
      refute Accounts.telegram_connected?(legacy_pat)
    end

    test "returns true once the patient's foundation row has telegram_chat_id_hash set", %{
      legacy_pro: legacy_pro,
      legacy_pat: legacy_pat
    } do
      {:ok, invite} = Accounts.invite_to_telegram(legacy_pat, legacy_pro)

      invite.patient
      |> Ecto.Changeset.change(%{telegram_chat_id_hash: valid_hash_for("connected")})
      |> Alethea.Repo.update!()

      assert Accounts.telegram_connected?(legacy_pat)
    end

    test "returns false for a non-legacy-patient struct (defensive guard)" do
      refute Accounts.telegram_connected?(%{})
      refute Accounts.telegram_connected?(nil)
    end
  end

  # --- helpers ---

  # A deterministic 64-char lowercase hex hash, the only input shape
  # `lookup_patient_by_chat_hash/1` is allowed to accept.
  defp valid_hash_for(seed) do
    :crypto.mac(:hmac, :sha256, "pepper-v1-32-bytes-min-len-padding-pad", "chat-#{seed}")
    |> Base.encode16(case: :lower)
  end

  # A hash that no patient row is bound to in the test DB.
  defp unbound_hash, do: valid_hash_for("unbound-#{System.unique_integer([:positive])}")

  # A legacy professional created through the canonical Accounts.create_professional/1
  # path (mints a KEK and stores it — fidelity to production). The optional
  # `tag` distinguishes fixtures within a single test.
  defp create_legacy_professional(tag \\ "ctx") do
    create_legacy_professional_with_password("supersecret12", tag)
  end

  defp create_legacy_professional_with_password(password, tag \\ "ctx") do
    Legacy.create_professional(%{
      email: "ctx-#{tag}-#{System.unique_integer([:positive])}@example.com",
      full_name: "Ctx #{tag} Pro",
      password: password
    })
  end

  # Legacy (`Alethea.Accounts.*`) fixtures for #108 tests, which
  # exercise the boundary between the foundation `Patient` schema
  # (provisioned by `invite_to_telegram/2`) and the legacy
  # `Alethea.Accounts.Patient` schema (the input).
  defp legacy_professional_fixture do
    {:ok, pro} =
      Alethea.Accounts.create_professional(%{
        email: "legacy-pro-#{System.unique_integer([:positive])}@example.com",
        password: "supersecret12",
        full_name: "Legacy Pro #{System.unique_integer([:positive])}"
      })

    pro
  end

  defp legacy_patient_fixture(pro, attrs) do
    kek_bytes = Keyword.fetch!(attrs, :kek_bytes)
    alias_value = Keyword.fetch!(attrs, :alias)

    {:ok, patient} =
      Alethea.Accounts.create_patient(
        %{
          "alias" => alias_value,
          "professional_id" => pro.id
        },
        kek_bytes
      )

    patient
  end
end
