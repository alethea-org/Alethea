defmodule AletheaWeb.TriggersLive.PaginationTest do
  use AletheaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Alethea.RagFixtures

  alias Alethea.Accounts
  alias Alethea.Clinical
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo
  alias Alethea.Triggers.{Trigger, TriggerFiring}

  @base ~U[2026-01-01 12:00:00Z]

  setup %{conn: conn} do
    professional = create_professional!()
    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "alias" => "Paciente #{System.unique_integer([:positive])}",
          "professional_id" => professional.id,
          "timezone" => "America/Santiago"
        },
        kek
      )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:professional_id, professional.id)

    %{conn: conn, professional: professional, patient: patient}
  end

  defp insert_trigger!(professional, patient, kind, index) do
    {:ok, dek} = Clinical.patient_dek(patient, "test_pagination")
    {:ok, instruction} = PatientVault.encrypt("Instruccion #{kind} #{index}", dek)
    at = DateTime.add(@base, index * 60, :second)

    shape =
      case kind do
        "active" ->
          %{
            scheduled_at: DateTime.add(@base, 86_400, :second),
            timezone: "America/Santiago",
            schedule_type: "once"
          }

        "reactive" ->
          {:ok, condition} = PatientVault.encrypt("Condicion #{index}", dek)
          %{condition: condition, cooldown_hours: 24}
      end

    struct!(
      Trigger,
      Map.merge(
        %{
          patient_id: patient.id,
          professional_id: professional.id,
          instruction: instruction,
          kind: kind,
          status: "inactive",
          inserted_at: at,
          updated_at: at
        },
        shape
      )
    )
    |> Repo.insert!()
  end

  defp insert_firing!(trigger, index) do
    fired_at = DateTime.add(@base, index * 60, :second)

    %TriggerFiring{}
    |> TriggerFiring.changeset(%{
      trigger_id: trigger.id,
      status: "skipped",
      fired_at: fired_at,
      scheduled_at: fired_at
    })
    |> Repo.insert!()
  end

  defp count_rows(html, prefix) do
    ~r/id="#{prefix}-[0-9a-f-]{36}"/ |> Regex.scan(html) |> length()
  end

  describe "scheduled triggers list" do
    test "renders the first 20 and loads the rest on demand", %{conn: conn} = ctx do
      for i <- 1..25, do: insert_trigger!(ctx.professional, ctx.patient, "active", i)

      {:ok, view, html} = live(conn, ~p"/patients/#{ctx.patient.id}/triggers")

      assert count_rows(html, "active-trigger") == 20
      assert has_element?(view, "#active-triggers.scroll-panel")
      assert has_element?(view, "#load-more-active-triggers", "Cargar más")

      html = view |> element("#load-more-active-triggers") |> render_click()

      assert count_rows(html, "active-trigger") == 25
      refute has_element?(view, "#load-more-active-triggers")
    end

    test "no load-more button with 20 or fewer", %{conn: conn} = ctx do
      for i <- 1..20, do: insert_trigger!(ctx.professional, ctx.patient, "active", i)

      {:ok, view, html} = live(conn, ~p"/patients/#{ctx.patient.id}/triggers")

      assert count_rows(html, "active-trigger") == 20
      refute has_element?(view, "#load-more-active-triggers")
      refute has_element?(view, "#active-triggers-empty")
    end
  end

  describe "reactive triggers list" do
    test "renders the first 20 and loads the rest on demand", %{conn: conn} = ctx do
      for i <- 1..25, do: insert_trigger!(ctx.professional, ctx.patient, "reactive", i)

      {:ok, view, html} = live(conn, ~p"/patients/#{ctx.patient.id}/triggers")

      assert count_rows(html, "reactive-trigger") == 20
      assert count_rows(html, "active-trigger") == 0
      assert has_element?(view, "#reactive-triggers.scroll-panel")
      assert has_element?(view, "#load-more-reactive-triggers", "Cargar más")
      assert has_element?(view, "#active-triggers-empty")

      html = view |> element("#load-more-reactive-triggers") |> render_click()

      assert count_rows(html, "reactive-trigger") == 25
      refute has_element?(view, "#load-more-reactive-triggers")
    end

    test "no load-more button with 20 or fewer", %{conn: conn} = ctx do
      for i <- 1..3, do: insert_trigger!(ctx.professional, ctx.patient, "reactive", i)

      {:ok, view, html} = live(conn, ~p"/patients/#{ctx.patient.id}/triggers")

      assert count_rows(html, "reactive-trigger") == 3
      refute has_element?(view, "#load-more-reactive-triggers")
    end
  end

  describe "firing history list" do
    test "renders the first 20 and loads the rest on demand", %{conn: conn} = ctx do
      trigger = insert_trigger!(ctx.professional, ctx.patient, "active", 1)
      for i <- 1..25, do: insert_firing!(trigger, i)

      {:ok, view, html} = live(conn, ~p"/patients/#{ctx.patient.id}/triggers")

      assert count_rows(html, "firing") == 20
      assert has_element?(view, "#trigger-firings.scroll-panel")
      assert has_element?(view, "#load-more-firings", "Cargar más")

      html = view |> element("#load-more-firings") |> render_click()

      assert count_rows(html, "firing") == 25
      refute has_element?(view, "#load-more-firings")

      # A second load-more after the end is a harmless no-op.
      html = render_hook(view, "load_more_firings", %{})
      assert count_rows(html, "firing") == 25
    end

    test "no load-more button with 20 or fewer", %{conn: conn} = ctx do
      trigger = insert_trigger!(ctx.professional, ctx.patient, "active", 1)
      for i <- 1..5, do: insert_firing!(trigger, i)

      {:ok, view, html} = live(conn, ~p"/patients/#{ctx.patient.id}/triggers")

      assert count_rows(html, "firing") == 5
      refute has_element?(view, "#load-more-firings")
    end
  end
end
