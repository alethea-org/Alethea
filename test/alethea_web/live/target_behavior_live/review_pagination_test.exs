defmodule AletheaWeb.TargetBehaviorLive.ReviewPaginationTest do
  @moduledoc """
  Pagination of the citation source feed (`#evidence-source-feed`) in the
  clinical review workbench: sources load 20 at a time instead of decrypting
  the whole patient record at once.
  """
  use AletheaWeb.ConnCase, async: true

  import Alethea.RagFixtures
  import Phoenix.LiveViewTest

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.ClinicalNote
  alias Alethea.Encryption.PatientVault

  setup %{conn: conn} do
    professional = create_professional!()
    patient = create_patient!(professional)

    {:ok, target_behavior} =
      ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta objetivo")

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:professional_id, professional.id)

    %{conn: conn, professional: professional, patient: patient, target_behavior: target_behavior}
  end

  defp insert_notes!(professional, patient, count) do
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)
    base = DateTime.utc_now() |> DateTime.truncate(:second)

    for n <- 1..count do
      {:ok, ciphertext} = PatientVault.encrypt("Fuente paginada #{n}", dek)

      %ClinicalNote{inserted_at: DateTime.add(base, n - count - 1, :minute)}
      |> ClinicalNote.changeset(%{
        patient_id: patient.id,
        professional_id: professional.id,
        encrypted_body: ciphertext
      })
      |> Alethea.Repo.insert!()
    end
  end

  defp open_citation(conn, patient, target_behavior) do
    {:ok, view, _html} =
      live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

    view |> element("#cite-evidence-header") |> render_click()
    view
  end

  defp rendered_source_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#evidence-source-feed .evidence-source-card")
    |> Enum.count()
  end

  test "renders the newest 20 sources in a scroll panel and loads the rest on demand", ctx do
    notes = insert_notes!(ctx.professional, ctx.patient, 25)
    view = open_citation(ctx.conn, ctx.patient, ctx.target_behavior)

    assert has_element?(view, "#evidence-source-feed.scroll-panel")
    assert has_element?(view, "#evidence-source-feed[phx-viewport-bottom=load_more_sources]")
    assert rendered_source_count(view) == 20
    assert has_element?(view, "#evidence-source-feed", "Fuente paginada 25")
    refute has_element?(view, "#evidence-source-feed", "Fuente paginada 5")
    assert has_element?(view, "#load-more-sources", "Cargar más")

    view |> element("#load-more-sources") |> render_click()

    assert rendered_source_count(view) == 25
    refute has_element?(view, "#load-more-sources")
    refute has_element?(view, "#evidence-source-feed[phx-viewport-bottom]")

    # A source from a later page can be selected (re-fetched, not looked up
    # in a server-side list).
    oldest = hd(notes)
    view |> element("#evidence-source-#{oldest.id}") |> render_click()

    assert has_element?(view, "#evidence-source-content", "Fuente paginada 1")
  end

  test "loading more after the end is harmless", ctx do
    insert_notes!(ctx.professional, ctx.patient, 25)
    view = open_citation(ctx.conn, ctx.patient, ctx.target_behavior)

    render_hook(view, "load_more_sources", %{})
    render_hook(view, "load_more_sources", %{})

    assert rendered_source_count(view) == 25
  end

  test "shows no load-more button with 20 sources or fewer", ctx do
    insert_notes!(ctx.professional, ctx.patient, 20)
    view = open_citation(ctx.conn, ctx.patient, ctx.target_behavior)

    assert rendered_source_count(view) == 20
    refute has_element?(view, "#load-more-sources")
  end

  test "an empty record keeps the empty message and no button", ctx do
    view = open_citation(ctx.conn, ctx.patient, ctx.target_behavior)

    assert has_element?(view, "#evidence-source-feed", "No hay notas ni mensajes disponibles")
    refute has_element?(view, "#load-more-sources")
  end
end
