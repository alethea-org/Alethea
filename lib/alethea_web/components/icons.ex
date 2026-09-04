defmodule AletheaWeb.Icons do
  @moduledoc """
  The application's icon set, rendered as inline SVG.

  The templates keep calling `<.icon name="hero-users" />` — the same
  API the project convention mandates — but the glyph is drawn here
  instead of resolved from a utility-class stylesheet. The previous
  implementation emitted `<span class="hero-users">` and relied on a
  Tailwind plugin to paint a mask into it; the app ships no Tailwind
  build, so every icon outside the handful daisyUI's fallback sheet
  happened to include rendered as an empty span.

  Every glyph is a 24×24 stroked path drawn on the same grid at
  stroke-width 1.5 with round caps and joins, so the set reads as one
  family. Color comes from `currentColor`, size from the `class`
  attribute (`size-3` … `size-6`, defined in `editorial.css`).
  """
  use Phoenix.Component

  @paths %{
    "hero-arrow-left-on-rectangle" => [
      "M9 16.5 4.5 12 9 7.5",
      "M4.5 12h10.5",
      "M14.25 4.5h3a2.25 2.25 0 0 1 2.25 2.25v10.5a2.25 2.25 0 0 1-2.25 2.25h-3"
    ],
    "hero-arrow-path" => [
      "M19.5 12a7.5 7.5 0 0 1-13.36 4.66",
      "M4.5 12a7.5 7.5 0 0 1 13.36-4.66",
      "M17.86 3.75v3.6h-3.6",
      "M6.14 20.25v-3.6h3.6"
    ],
    "hero-bars-3" => ["M3.75 6.75h16.5", "M3.75 12h16.5", "M3.75 17.25h16.5"],
    "hero-bell" => [
      "M18 8.25a6 6 0 1 0-12 0c0 3.11-.78 5.2-1.72 6.44a.75.75 0 0 0 .6 1.2h14.24a.75.75 0 0 0 .6-1.2C18.78 13.45 18 11.36 18 8.25Z",
      "M9.75 18.75a2.25 2.25 0 0 0 4.5 0"
    ],
    "hero-bell-slash" => [
      "M18 8.25a6 6 0 0 0-8.53-5.44",
      "M6.14 6.4A6 6 0 0 0 6 8.25c0 3.11-.78 5.2-1.72 6.44a.75.75 0 0 0 .6 1.2h12.37",
      "M9.75 18.75a2.25 2.25 0 0 0 4.5 0",
      "M3 3l18 18"
    ],
    "hero-chat-bubble-left-right" => [
      "M8.25 13.5H5.25A2.25 2.25 0 0 1 3 11.25v-4.5A2.25 2.25 0 0 1 5.25 4.5h7.5A2.25 2.25 0 0 1 15 6.75v.75",
      "M6 13.5v3l3-3",
      "M11.25 9.75h7.5A2.25 2.25 0 0 1 21 12v4.5a2.25 2.25 0 0 1-2.25 2.25H18v3l-3.75-3h-3A2.25 2.25 0 0 1 9 16.5V12a2.25 2.25 0 0 1 2.25-2.25Z"
    ],
    "hero-check" => ["M4.5 12.75l6 6 9-13.5"],
    "hero-chevron-left" => ["M15.75 19.5 8.25 12l7.5-7.5"],
    "hero-chevron-right" => ["M8.25 4.5l7.5 7.5-7.5 7.5"],
    "hero-circle-stack" => [
      "M20.25 6.375c0 2.278-3.694 4.125-8.25 4.125S3.75 8.653 3.75 6.375m16.5 0c0-2.278-3.694-4.125-8.25-4.125S3.75 4.097 3.75 6.375m16.5 0v11.25c0 2.278-3.694 4.125-8.25 4.125s-8.25-1.847-8.25-4.125V6.375m16.5 3.75c0 2.278-3.694 4.125-8.25 4.125s-8.25-1.847-8.25-4.125"
    ],
    "hero-clock" => [
      "M12 6v6h4.5m4.5 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"
    ],
    "hero-exclamation-circle" => [
      "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
      "M12 7.5v5.25",
      "M12 16.5h.01"
    ],
    "hero-information-circle" => [
      "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
      "M12 16.5v-5.25h-.75",
      "M11.25 16.5h1.5",
      "M12 7.75h.01"
    ],
    "hero-link" => [
      "M13.19 8.688a4.5 4.5 0 0 1 1.242 7.244l-4.5 4.5a4.5 4.5 0 0 1-6.364-6.364l1.757-1.757m13.35-.622 1.757-1.757a4.5 4.5 0 0 0-6.364-6.364l-4.5 4.5a4.5 4.5 0 0 0 1.242 7.244"
    ],
    "hero-lock-closed" => [
      "M16.5 10.5V6.75a4.5 4.5 0 1 0-9 0v3.75",
      "M6.75 10.5h10.5a1.5 1.5 0 0 1 1.5 1.5v6.75a1.5 1.5 0 0 1-1.5 1.5H6.75a1.5 1.5 0 0 1-1.5-1.5V12a1.5 1.5 0 0 1 1.5-1.5Z"
    ],
    "hero-magnifying-glass" => [
      "M17.25 10.5a6.75 6.75 0 1 1-13.5 0 6.75 6.75 0 0 1 13.5 0Z",
      "M21 21l-4.35-4.35"
    ],
    "hero-megaphone" => [
      "M10.5 8.25 18.66 4.2a.75.75 0 0 1 1.09.67v14.26a.75.75 0 0 1-1.09.67L10.5 15.75",
      "M10.5 8.25v7.5",
      "M10.5 15.75H5.25a1.5 1.5 0 0 1-1.5-1.5v-4.5a1.5 1.5 0 0 1 1.5-1.5h5.25",
      "M7.5 15.75v3a1.5 1.5 0 0 0 3 0v-3"
    ],
    "hero-plus" => ["M12 4.5v15", "M19.5 12h-15"],
    "hero-presentation-chart-line" => [
      "M2.25 3h19.5",
      "M3.75 3v11.25a1.5 1.5 0 0 0 1.5 1.5h13.5a1.5 1.5 0 0 0 1.5-1.5V3",
      "M7.5 12.75l2.25-2.25 2.25 2.25 3.75-4.5",
      "M7.5 21l4.5-5.25L16.5 21"
    ],
    "hero-shield-check" => [
      "M12 3l7.5 2.7v5.55c0 4.6-3.1 8.9-7.5 10.05C7.6 20.15 4.5 15.85 4.5 11.25V5.7L12 3Z",
      "M9 12l2.25 2.25 4.5-4.5"
    ],
    "hero-user-circle" => [
      "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
      "M15 10.5a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z",
      "M6 18.6a6.75 6.75 0 0 1 12 0"
    ],
    "hero-user-plus" => [
      "M12 7.5a3.75 3.75 0 1 1-7.5 0 3.75 3.75 0 0 1 7.5 0Z",
      "M2.25 20.25a6 6 0 0 1 12 0",
      "M18.75 7.5v5.25",
      "M21.375 10.125h-5.25"
    ],
    "hero-users" => [
      "M12 7.5a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z",
      "M3 19.5V18a4.5 4.5 0 0 1 4.5-4.5h3A4.5 4.5 0 0 1 15 18v1.5",
      "M15.75 4.65a3 3 0 0 1 0 5.7",
      "M17.62 13.65A4.5 4.5 0 0 1 21 18v1.5"
    ],
    "hero-x-mark" => ["M6 18 18 6", "M6 6l12 12"]
  }

  @doc """
  Renders one icon from the set.

  ## Examples

      <.icon name="hero-users" />
      <.icon name="hero-plus" class="size-3" />
  """
  attr(:name, :string, required: true)
  attr(:class, :any, default: nil)
  attr(:rest, :global)

  def icon(assigns) do
    assigns = assign(assigns, :paths, Map.get(@paths, assigns.name, []))

    ~H"""
    <svg
      class={["icon", @class]}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      {@rest}
    >
      <path :for={d <- @paths} d={d} />
    </svg>
    """
  end

  @doc """
  The names this set can draw. Used by the icon coverage test so a
  template can never reference a glyph the set does not carry.
  """
  def names, do: Map.keys(@paths)
end
