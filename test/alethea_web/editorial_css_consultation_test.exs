defmodule AletheaWeb.EditorialCssConsultationTest do
  use ExUnit.Case, async: true

  @css_path Path.expand("../../priv/static/assets/css/editorial.css", __DIR__)

  @required_classes [
    "citation",
    "citation-list",
    "citation__summary",
    "citation__kind",
    "citation__date",
    "citation__ref",
    "citation__link",
    "citation__excerpt",
    "review-hypothesis-panel",
    "review-hypothesis-panel__disclaimer",
    "review-hypothesis-panel__statement",
    "consultation",
    "consultation-synthesis",
    "consultation__synthesis",
    "consultation__sources-panel",
    "consultation__section-title",
    "consultation__source-link",
    "consultation__thread",
    "consultation__messages",
    "consultation__turn",
    "consultation__turn-query",
    "consultation__turn-query-text"
  ]

  setup_all do
    assert File.exists?(@css_path), "Expected #{@css_path} to exist"
    css = File.read!(@css_path)
    {:ok, css: css}
  end

  describe "editorial.css consultation and grounded chat classes" do
    test "defines rules for all required consultation classes", %{css: css} do
      missing =
        Enum.reject(@required_classes, fn class ->
          pattern = ~r/\.#{Regex.escape(class)}(?![a-zA-Z0-9_-])/
          Regex.match?(pattern, css)
        end)

      assert missing == [],
             "Expected priv/static/assets/css/editorial.css to define rules for: #{Enum.join(missing, ", ")}"
    end

    for class <- @required_classes do
      @class class
      test "defines rule for .#{@class}", %{css: css} do
        pattern = ~r/\.#{Regex.escape(@class)}(?![a-zA-Z0-9_-])/

        assert Regex.match?(pattern, css),
               "Expected priv/static/assets/css/editorial.css to define a rule for .#{@class}"
      end
    end
  end
end
