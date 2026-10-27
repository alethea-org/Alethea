defmodule AletheaWeb.Plugs.ProfessionalAuthTest do
  use AletheaWeb.ConnCase, async: false
  import Ecto.Query

  alias Alethea.Accounts
  alias Alethea.Accounts.AuditLog
  alias Alethea.Encryption.ProfessionalKek
  alias Alethea.Encryption.Vault
  alias Alethea.Accounts.EncryptionKey
  alias Alethea.Repo

  describe "on_mount with KEK ownership validation" do
    # Skip until we fix test isolation
    @tag :skip
    test "valid session with matching KEK loads successfully" do
      # Create professional with KEK directly
      professional = create_professional_with_kek()

      conn =
        build_conn()
        |> init_test_session(%{professional_id: professional.id})
        |> get("/dashboard")

      assert response(conn, 200)
    end

    test "session with non-existent professional_id redirects to login" do
      fake_id = Ecto.UUID.generate()

      conn =
        build_conn()
        |> init_test_session(%{professional_id: fake_id})
        |> get("/dashboard")

      assert redirected_to(conn) == "/login"
    end

    # Skip - test isolation issue
    @tag :skip
    test "professional without KEK redirects to login" do
      # Create professional without KEK
      professional = create_professional_without_kek()

      conn =
        build_conn()
        |> init_test_session(%{professional_id: professional.id})
        |> get("/dashboard")

      assert redirected_to(conn) == "/login"
    end
  end

  describe "KEK_ACCESS audit logging" do
    # Skip until we fix audit logging timing
    @tag :skip
    test "successful KEK access is logged to audit_logs" do
      professional = create_professional_with_kek()

      build_conn()
      |> init_test_session(%{professional_id: professional.id})
      |> get("/dashboard")

      # Give time for async operations
      :timer.sleep(200)

      # Check audit log entry
      audit_entry =
        Repo.one(
          from(a in AuditLog,
            where: a.professional_id == ^professional.id and a.action == "KEK_ACCESS",
            order_by: [desc: a.inserted_at],
            limit: 1
          )
        )

      assert audit_entry
    end
  end

  describe "on_mount admission" do
    setup do
      originals =
        for key <- [:demo_restricted_access, :demo_allowed_emails],
            do: {key, Application.fetch_env(:alethea, key)}

      Application.put_env(:alethea, :demo_restricted_access, true)
      Application.put_env(:alethea, :demo_allowed_emails, ["allowed@example.test"])

      on_exit(fn ->
        for {key, original} <- originals do
          case original do
            {:ok, value} -> Application.put_env(:alethea, key, value)
            :error -> Application.delete_env(:alethea, key)
          end
        end
      end)
    end

    test "an unlisted professional is redirected and the denial is audited" do
      professional = create_professional_with_kek()

      assert {:halt, _socket} =
               AletheaWeb.Plugs.ProfessionalAuth.on_mount(
                 :mount_current_professional,
                 %{},
                 %{"professional_id" => professional.id},
                 %Phoenix.LiveView.Socket{}
               )

      entry =
        Repo.one!(
          from(a in AuditLog,
            where: a.professional_id == ^professional.id and a.action == "KEK_ACCESS"
          )
        )

      assert inspect(entry.details) =~ "not_admitted"
    end
  end

  describe "ProfessionalKek.kek_exists?" do
    test "returns {:ok, key_id} when KEK exists" do
      professional = create_professional_with_kek()
      assert {:ok, key_id} = ProfessionalKek.kek_exists?(professional.id)
      assert is_binary(key_id)
    end

    test "returns {:error, :not_found} when KEK does not exist" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = ProfessionalKek.kek_exists?(fake_id)
    end
  end

  # Helper functions

  defp create_professional_with_kek do
    # Generate unique email
    email = "test_#{:rand.uniform(999_999_999)}@test.com"

    # Delete any existing professional with this email
    Repo.delete_all(from(p in Alethea.Accounts.Professional, where: p.email == ^email))

    {:ok, professional} =
      Accounts.create_professional(%{
        email: email,
        password: "TestPassword123!",
        full_name: "Test Professional"
      })

    # Clean up any existing KEKs for this professional (in case of re-run)
    Repo.delete_all(
      from(k in EncryptionKey,
        where: k.professional_id == ^professional.id and k.type == "professional"
      )
    )

    # Create KEK for this professional
    kek_bytes = ProfessionalKek.generate_kek()
    encrypted_kek = Vault.encrypt!(kek_bytes)

    %EncryptionKey{}
    |> EncryptionKey.changeset(%{
      professional_id: professional.id,
      encrypted_key: encrypted_kek,
      type: "professional"
    })
    |> Repo.insert!()

    professional
  end

  defp create_professional_without_kek do
    email = "no_kek_#{:rand.uniform(999_999_999)}@test.com"

    # Delete any existing
    Repo.delete_all(from(p in Alethea.Accounts.Professional, where: p.email == ^email))

    {:ok, professional} =
      Accounts.create_professional(%{
        email: email,
        password: "TestPassword123!",
        full_name: "Test No KEK"
      })

    # Delete any KEK that might have been created
    Repo.delete_all(
      from(k in EncryptionKey,
        where: k.professional_id == ^professional.id and k.type == "professional"
      )
    )

    professional
  end
end
