defmodule AletheaWeb.ErrorHTMLTest do
  use AletheaWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  describe "custom error pages" do
    test "renders 404.html as a full editorial document" do
      html = render_to_string(AletheaWeb.ErrorHTML, "404", "html", [])

      assert html =~ "Error 404"
      assert html =~ "Esta página no existe."
      # The page has to stand on its own: it is rendered with
      # `layout: false`, so it must carry the document shell and both
      # stylesheets itself.
      assert html =~ "<!DOCTYPE html>"
      assert html =~ "/assets/css/editorial.css"
    end

    test "renders 500.html as a full editorial document" do
      html = render_to_string(AletheaWeb.ErrorHTML, "500", "html", [])

      assert html =~ "Error 500"
      assert html =~ "Algo se rompió de nuestro lado."
      assert html =~ "<!DOCTYPE html>"
      assert html =~ "/assets/css/editorial.css"
    end
  end

  describe "statuses without a template" do
    test "fall back to the plain status message" do
      assert render_to_string(AletheaWeb.ErrorHTML, "403", "html", []) == "Forbidden"
      assert render_to_string(AletheaWeb.ErrorHTML, "503", "html", []) == "Service Unavailable"
    end
  end
end
