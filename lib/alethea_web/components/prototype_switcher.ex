defmodule AletheaWeb.Components.PrototypeSwitcher do
  @moduledoc """
  PROTOTYPE — THROWAWAY. Floating variant switcher for wayfinder ticket
  #116 ("Layout & visual disposition: dashboard + onboarding").

  Renders a fixed bottom-centre pill that cycles the `?variant=` search
  param and cycles `?theme=` through the palettes. Hidden outside
  `:dev_routes` so a stray merge cannot ship it.

  Delete together with the `*_prototype_variants.ex` modules and
  `prototype.css` once a variant wins.
  """
  use AletheaWeb, :html

  @enabled Application.compile_env(:alethea, :dev_routes, false)

  @themes [{"default", "Frío"}, {"warm", "Cálido"}, {"editorial", "Editorial"}]

  attr(:variants, :list, required: true, doc: "list of {key, name} tuples")
  attr(:current, :string, required: true)
  attr(:base_path, :string, required: true)
  attr(:theme, :string, default: "default")

  def prototype_switcher(assigns) do
    keys = Enum.map(assigns.variants, &elem(&1, 0))
    index = Enum.find_index(keys, &(&1 == assigns.current)) || 0
    count = length(keys)

    theme_keys = Enum.map(@themes, &elem(&1, 0))
    theme_index = Enum.find_index(theme_keys, &(&1 == assigns.theme)) || 0
    next_theme = Enum.at(theme_keys, rem(theme_index + 1, length(theme_keys)))

    href = fn variant, theme ->
      "#{assigns.base_path}?variant=#{variant}&theme=#{theme}"
    end

    assigns =
      assigns
      |> assign(:enabled, @enabled)
      |> assign(:theme_label, @themes |> Enum.at(theme_index) |> elem(1))
      |> assign(:themed?, assigns.theme != "default")
      |> assign(:name, assigns.variants |> Enum.at(index) |> elem(1))
      |> assign(:prev_href, href.(Enum.at(keys, rem(index - 1 + count, count)), assigns.theme))
      |> assign(:next_href, href.(Enum.at(keys, rem(index + 1, count)), assigns.theme))
      |> assign(:theme_href, href.(assigns.current, next_theme))
      |> assign(:current_key, assigns.current)

    ~H"""
    <div
      :if={@enabled}
      id="prototype-switcher"
      class="pt-switcher"
      data-prev={@prev_href}
      data-next={@next_href}
    >
      <a class="pt-switcher__arrow" href={@prev_href} aria-label="Variante anterior">
        &#8592;
      </a>
      <span class="pt-switcher__label">
        <span class="pt-switcher__key">{@current_key}</span>{@name}
        <span class="pt-switcher__tag">Prototipo #116</span>
      </span>
      <a class="pt-switcher__arrow" href={@next_href} aria-label="Variante siguiente">
        &#8594;
      </a>
      <a
        class={["pt-switcher__theme", @themed? && "pt-switcher__theme--on"]}
        href={@theme_href}
        aria-label="Cambiar paleta"
      >
        {@theme_label}
      </a>
    </div>

    <script :if={@enabled} defer src={~p"/assets/js/prototype_switcher.js"}>
    </script>
    """
  end
end
