defmodule AletheaWeb.EorcShapeComparisonPrototypeLiveTest do
  use AletheaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Alethea.Accounts

  setup %{conn: conn} do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "eorc-shape-#{System.unique_integer([:positive])}@alethea.test",
        full_name: "EORC Shape Professional",
        password: "password1234"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{professional_id: professional.id})

    %{conn: conn}
  end

  test "renders the side-by-side comparison page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prototype/eorc-shape")

    assert has_element?(view, "#eorc-shape-comparison-prototype")
    assert has_element?(view, ".esc-draft--flat")
    assert has_element?(view, ".esc-draft--expanded")
    assert has_element?(view, "#esc-gap-panel")
  end

  test "shows the gap panel by default and toggles it on demand", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prototype/eorc-shape")

    assert has_element?(view, "#esc-gap-panel")

    view |> element("#toggle-gap-panel") |> render_click()
    refute has_element?(view, "#esc-gap-panel")

    view |> element("#toggle-gap-panel") |> render_click()
    assert has_element?(view, "#esc-gap-panel")
  end

  test "shows the same shared source notes and immutable citations on both drafts", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prototype/eorc-shape")

    assert has_element?(view, "#esc-source-1")
    assert has_element?(view, "#esc-source-2")
    assert has_element?(view, "#esc-excerpt-1")
    assert has_element?(view, "#esc-excerpt-2")
  end
end
