defmodule AletheaWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use AletheaWeb, :html

  embed_templates "page_html/*"

  @tour_steps [
    {"invitacion", "Invitación"},
    {"diario", "Diario con IA y triggers"},
    {"emociones", "Análisis de emociones"},
    {"crisis", "Detección de crisis"},
    {"briefing", "Briefing semanal"},
    {"historia-clinica", "Historia clínica conversacional"},
    {"sesiones", "Sesiones grabadas"},
    {"analisis-funcional", "Análisis funcional"},
    {"notas", "Notas clínicas"},
    {"privacidad", "Privacidad"}
  ]

  @doc "Landing tour scenes as `{anchor_id, label}`, in page order."
  def tour_steps, do: @tour_steps

  @doc """
  One scene of the landing's scroll story.

  The text is a title plus short `beats`. On wide screens `landing.js` pins
  the scene and shows one beat at a time as the reader scrolls; elements in
  the visual slot carrying `data-at="N"` appear from beat N on. Elsewhere
  (narrow screens, reduced motion, no JS) the beats stack and the visual
  renders complete.
  """
  attr :id, :string, required: true
  attr :eyebrow, :string, required: true
  attr :title, :string, required: true
  attr :beats, :list, required: true
  attr :duo, :boolean, default: false, doc: "lay the visual out as two columns (card + phone)"
  slot :inner_block, required: true

  def scene(assigns) do
    steps = tour_steps()
    index = Enum.find_index(steps, fn {id, _label} -> id == assigns.id end)

    assigns =
      assigns
      |> assign(:number, pad(index + 1))
      |> assign(:total, pad(length(steps)))

    ~H"""
    <section class="lx-scene" id={@id} data-scene style={"--beats:#{length(@beats)}"}>
      <div class="lx-stage">
        <div class="lx-shell lx-stage__grid">
          <div class="lx-stage__text">
            <p class="lx-count">
              <span>{@number} / {@total}</span> {@eyebrow}
            </p>
            <h2 class="lx-h2">{@title}</h2>
            <div class="lx-beats">
              <p :for={{beat, i} <- Enum.with_index(@beats, 1)} class="lx-beat" data-beat={i}>
                {beat}
              </p>
            </div>
            <div class="lx-ticks" aria-hidden="true">
              <i :for={i <- 1..length(@beats)} data-tick={i}></i>
            </div>
          </div>
          <div class={["lx-stage__visual", @duo && "lx-stage__visual--duo"]} aria-hidden="true">
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # Illustrative week for the emotion-trend mockup: percentages per label.
  @emotion_week [
    {"L", [joy: 15, sad: 20, anger: 10, fear: 35, neutral: 20]},
    {"M", [joy: 10, sad: 25, anger: 30, fear: 20, neutral: 15]},
    {"M", [joy: 20, sad: 15, anger: 15, fear: 30, neutral: 20]},
    {"J", [joy: 10, sad: 20, anger: 35, fear: 25, neutral: 10]},
    {"V", [joy: 25, sad: 15, anger: 10, fear: 25, neutral: 25]},
    {"S", [joy: 45, sad: 10, anger: 5, fear: 10, neutral: 30]},
    {"D", [joy: 40, sad: 15, anger: 5, fear: 10, neutral: 30]}
  ]

  @doc "Sample seven-day emotion mix shown in the landing's trend mockup."
  def emotion_week do
    Enum.map(@emotion_week, fn {label, mix} -> %{label: label, mix: mix} end)
  end
end
