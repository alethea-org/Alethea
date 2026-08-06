defmodule AletheaWeb.Components.PrototypeSwitcher do
  @moduledoc """
  PROTOTYPE — THROWAWAY. Floating variant switcher for wayfinder ticket
  #116 ("Layout & visual disposition: dashboard + onboarding").

  Renders a fixed bottom-centre pill that cycles the `?variant=` search
  param. Hidden outside `:dev_routes` so a stray merge cannot ship it.

  Delete together with the `*_prototype_variants.ex` modules and
  `prototype.css` once a variant wins.
  """
  use AletheaWeb, :html

  @enabled Application.compile_env(:alethea, :dev_routes, false)

  attr(:variants, :list, required: true, doc: "list of {key, name} tuples")
  attr(:current, :string, required: true)
  attr(:base_path, :string, required: true)

  def prototype_switcher(assigns) do
    keys = Enum.map(assigns.variants, &elem(&1, 0))
    index = Enum.find_index(keys, &(&1 == assigns.current)) || 0
    count = length(keys)

    assigns =
      assigns
      |> assign(:enabled, @enabled)
      |> assign(:name, assigns.variants |> Enum.at(index) |> elem(1))
      |> assign(:prev, Enum.at(keys, rem(index - 1 + count, count)))
      |> assign(:next, Enum.at(keys, rem(index + 1, count)))

    ~H"""
    <div
      :if={@enabled}
      id="prototype-switcher"
      class="pt-switcher"
      data-prev={"#{@base_path}?variant=#{@prev}"}
      data-next={"#{@base_path}?variant=#{@next}"}
    >
      <a
        class="pt-switcher__arrow"
        href={"#{@base_path}?variant=#{@prev}"}
        aria-label="Variante anterior"
      >
        &#8592;
      </a>
      <span class="pt-switcher__label">
        <span class="pt-switcher__key">{@current}</span>{@name}
        <span class="pt-switcher__tag">Prototipo #116</span>
      </span>
      <a
        class="pt-switcher__arrow"
        href={"#{@base_path}?variant=#{@next}"}
        aria-label="Variante siguiente"
      >
        &#8594;
      </a>
    </div>

    <script :if={@enabled} defer src={~p"/assets/js/prototype_switcher.js"}>
    </script>
    """
  end
end
