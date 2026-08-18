defmodule AletheaWeb.IconsTest do
  @moduledoc """
  Guards the icon set against the failure mode it was built to fix.

  Icons used to render through a utility-class stylesheet the app
  never compiled, so a missing glyph was invisible rather than loud.
  Now the set draws inline SVG — but an unknown name still renders an
  empty `<svg>`, which fails the same silent way. These tests make the
  gap visible in CI instead of in the browser.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AletheaWeb.Icons

  @template_globs [
    "lib/alethea_web/**/*.ex",
    "lib/alethea_web/**/*.heex"
  ]

  describe "icon/1" do
    test "draws at least one path for every name in the set" do
      for name <- Icons.names() do
        html = render_component(&Icons.icon/1, name: name)

        assert html =~ "<path", "#{name} rendered no path"
        assert html =~ ~s(stroke="currentColor"), "#{name} does not inherit its color"
      end
    end

    test "size comes from the class, not from a hardcoded attribute" do
      html = render_component(&Icons.icon/1, name: "hero-users", class: "size-5")

      assert html =~ "icon size-5"
      # `stroke-width` is part of the family's line weight, not a size,
      # so the guard has to target a standalone `width` attribute.
      refute html =~ ~s( width=")
      refute html =~ ~s( height=")
    end
  end

  describe "coverage" do
    test "every hero-* name referenced by a template exists in the set" do
      known = MapSet.new(Icons.names())

      referenced =
        @template_globs
        |> Enum.flat_map(&Path.wildcard/1)
        # The set itself is the definition, not a reference to one.
        |> Enum.reject(&String.ends_with?(&1, "components/icons.ex"))
        |> Enum.flat_map(fn path ->
          # Anchored on the `name` attribute: `hero-card-dark` is a
          # signature-card CSS class, not a glyph.
          Regex.scan(~r/name=\{?"(hero-[a-z0-9-]+)"/, File.read!(path))
          |> Enum.map(fn [_, name] -> name end)
        end)
        |> MapSet.new()

      missing = MapSet.difference(referenced, known)

      assert MapSet.size(missing) == 0,
             "templates reference glyphs the icon set cannot draw: #{inspect(MapSet.to_list(missing))}"
    end
  end
end
