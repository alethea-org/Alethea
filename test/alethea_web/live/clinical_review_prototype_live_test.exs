defmodule AletheaWeb.ClinicalReviewPrototypeLiveTest do
  use AletheaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Alethea.Accounts

  setup %{conn: conn} do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "clinical-review-#{System.unique_integer([:positive])}@alethea.test",
        full_name: "Clinical Review Professional",
        password: "password1234"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{professional_id: professional.id})

    %{conn: conn}
  end

  test "renders every clinical review prototype variant", %{conn: conn} do
    for {variant, selector} <- [
          {"review", ".crp-review-bench"},
          {"timeline", ".crp-timeline-layout"},
          {"matrix", ".crp-matrix-layout"},
          {"hybrid", "#hybrid-rag-freshness"}
        ] do
      {:ok, view, _html} = live(conn, ~p"/prototype/clinical-review?variant=#{variant}")
      assert has_element?(view, "#clinical-review-prototype")
      assert has_element?(view, selector)
    end
  end

  test "reveals the contradiction comparison only on demand in the hybrid variant", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prototype/clinical-review?variant=hybrid")

    refute has_element?(view, "#hybrid-contradiction-comparison")
    view |> element("#toggle-contradiction-comparison") |> render_click()
    assert has_element?(view, "#hybrid-contradiction-comparison")
  end

  test "hybrid variant renders separated synthesis + hypothesis panels with disclaimer and expandable citations",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/prototype/clinical-review?variant=hybrid")

    assert has_element?(view, "#hybrid-evidence-synthesis-panel")
    assert has_element?(view, "#hybrid-hypothesis-panel")
    assert has_element?(view, "#hybrid-hypothesis-disclaimer")
    assert has_element?(view, "#hybrid-hypothesis-claim-1 details summary")
    assert has_element?(view, "#hybrid-hypothesis-claim-1 a[href='#hybrid-source-1']")

    {evidence_pos, _} = :binary.match(html, "hybrid-evidence-synthesis-panel")
    {hypothesis_pos, _} = :binary.match(html, "hybrid-hypothesis-panel")
    {disclaimer_pos, _} = :binary.match(html, "hybrid-hypothesis-disclaimer")
    {first_claim_pos, _} = :binary.match(html, "hybrid-hypothesis-claim-1")

    assert evidence_pos < hypothesis_pos
    assert disclaimer_pos < first_claim_pos
  end

  test "hybrid variant omits hypothesis panel when the query is not interpretive", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prototype/clinical-review?variant=hybrid&interpretive=false")

    assert has_element?(view, "#hybrid-evidence-synthesis-panel")
    refute has_element?(view, "#hybrid-hypothesis-panel")
    refute has_element?(view, "#hybrid-hypothesis-disclaimer")
  end
end
