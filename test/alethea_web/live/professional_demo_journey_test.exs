defmodule AletheaWeb.ProfessionalDemoJourneyTest do
  use AletheaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Alethea.Accounts
  alias Alethea.Encryption.PatientVault
  alias Alethea.Foundation.Accounts, as: FoundationAccounts
  alias Alethea.Foundation.Accounts.BotConfig

  test "registration and login lead to an encrypted first patient Telegram invite", %{conn: conn} do
    Application.put_env(:alethea, :use_mock_data, false)
    on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)

    email = "journey-#{System.unique_integer([:positive])}@alethea.test"
    password = "journey-password-123"

    conn =
      conn
      |> post("/register", %{
        "professional" => %{
          "email" => email,
          "full_name" => "Journey Professional",
          "password" => password
        }
      })
      |> recycle()
      |> post("/login", %{"professional" => %{"email" => email, "password" => password}})

    assert redirected_to(conn) == "/dashboard"

    professional = Accounts.get_professional_by_email(email)

    {:ok, patient_view, _html} = live(conn, ~p"/patients/new")

    patient_view
    |> form("#patient-form", patient: %{alias: "First Journey Patient"})
    |> render_submit()

    patient =
      professional.id
      |> Accounts.list_patients()
      |> Enum.find(&(&1.alias == "First Journey Patient"))

    assert patient
    assert {:ok, kek} = Accounts.load_professional_kek(professional)

    assert {:ok, dek} =
             patient.id
             |> Accounts.get_encryption_key_for_patient()
             |> then(&PatientVault.decrypt(&1.encrypted_key, kek))

    assert byte_size(dek) == 32

    assert {:ok, _bot_config} =
             BotConfig.upsert(%{
               env: "test",
               bot_token: "journey-test-token",
               secret_token: "journey-test-secret",
               bot_username: "journey_test_bot"
             })

    {:ok, dashboard_view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")
    dashboard_view |> element("#tg-btn-#{patient.id}") |> render_click()

    assert has_element?(dashboard_view, "#telegram-invite-panel")

    assert has_element?(
             dashboard_view,
             ~s|#invite-deep-link[href^="https://t.me/journey_test_bot?start="]|
           )

    assert {:ok, foundation_pro} = FoundationAccounts.professional_by_email(email)
    assert foundation_pro.legacy_professional_id == professional.id
  end
end
