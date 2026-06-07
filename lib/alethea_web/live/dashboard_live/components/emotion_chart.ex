defmodule AletheaWeb.DashboardLive.Components.EmotionChart do
  use Phoenix.Component

  # SVG layout constants (viewBox "0 0 560 200")
  @chart_left 40
  @chart_top 10
  @chart_bottom 170
  @chart_w 512
  @bar_w 10
  @bar_gap 2

  @emotions [
    {:joy, "Alegría", "#22c55e"},
    {:sadness, "Tristeza", "#3b82f6"},
    {:anger, "Ira", "#ef4444"},
    {:fear, "Miedo", "#f59e0b"},
    {:neutral, "Neutro", "#94a3b8"}
  ]

  # daily_data: list of %{date: Date.t(), joy: float, sadness: float, anger: float, fear: float, neutral: float}
  attr :daily_data, :list, default: []

  def emotion_chart(assigns) do
    today = Date.utc_today()
    days = for i <- 0..6, do: Date.add(today, i - 6)

    data_by_date = Map.new(assigns.daily_data, fn row -> {row.date, row} end)

    chart_h = @chart_bottom - @chart_top
    group_w = @chart_w / 7.0
    bars_total_w = length(@emotions) * @bar_w + (length(@emotions) - 1) * @bar_gap
    group_pad = (group_w - bars_total_w) / 2.0

    emotion_keys = Enum.map(@emotions, fn {k, _, _} -> k end)
    emotion_colors = Map.new(@emotions, fn {k, _, c} -> {k, c} end)

    bars =
      for {date, day_idx} <- Enum.with_index(days),
          {key, emo_idx} <- Enum.with_index(emotion_keys) do
        entry = Map.get(data_by_date, date, %{})
        score = to_float(Map.get(entry, key))
        bar_h = if score > 0, do: max(score * chart_h, 2.0), else: 0.0
        gx = @chart_left + day_idx * group_w

        %{
          x: Float.round(gx + group_pad + emo_idx * (@bar_w + @bar_gap), 1),
          y: Float.round(@chart_bottom - bar_h, 1),
          w: @bar_w,
          h: Float.round(bar_h, 1),
          fill: Map.get(emotion_colors, key)
        }
      end

    day_labels =
      for {date, idx} <- Enum.with_index(days) do
        %{
          x: Float.round(@chart_left + idx * group_w + group_w / 2.0, 1),
          y: @chart_bottom + 14,
          label: short_day(date)
        }
      end

    assigns =
      assigns
      |> assign(:bars, bars)
      |> assign(:day_labels, day_labels)
      |> assign(:emotions, @emotions)

    ~H"""
    <div>
      <svg
        viewBox="0 0 560 200"
        xmlns="http://www.w3.org/2000/svg"
        style="width:100%; height:auto; display:block;"
        aria-label="Gráfico de emociones últimos 7 días"
      >
        <%!-- horizontal grid lines --%>
        <line x1="40" y1="10" x2="552" y2="10" stroke="#e2e8f0" stroke-width="1" />
        <line
          x1="40"
          y1="90"
          x2="552"
          y2="90"
          stroke="#e2e8f0"
          stroke-width="1"
          stroke-dasharray="3,3"
        />
        <line x1="40" y1="170" x2="552" y2="170" stroke="#e2e8f0" stroke-width="1" />

        <%!-- y-axis labels --%>
        <text x="34" y="13" text-anchor="end" font-size="9" fill="#94a3b8">100%</text>
        <text x="34" y="93" text-anchor="end" font-size="9" fill="#94a3b8">50%</text>
        <text x="34" y="173" text-anchor="end" font-size="9" fill="#94a3b8">0%</text>

        <%!-- bars --%>
        <%= for bar <- @bars do %>
          <rect
            x={bar.x}
            y={bar.y}
            width={bar.w}
            height={bar.h}
            fill={bar.fill}
            rx="2"
            opacity="0.85"
          />
        <% end %>

        <%!-- x-axis day labels --%>
        <%= for lbl <- @day_labels do %>
          <text x={lbl.x} y={lbl.y} text-anchor="middle" font-size="9" fill="#94a3b8">
            {lbl.label}
          </text>
        <% end %>
      </svg>

      <%!-- legend --%>
      <div style="display:flex; flex-wrap:wrap; gap:6px 14px; margin-top:4px; padding:0 40px;">
        <%= for {_key, label, color} <- @emotions do %>
          <div style="display:flex; align-items:center; gap:4px;">
            <span style={"width:10px; height:10px; border-radius:2px; background:#{color}; flex-shrink:0; display:inline-block;"}>
            </span>
            <span style="font-size:10px; color:#64748b;">{label}</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v * 1.0
  defp to_float(_), do: 0.0

  defp short_day(date) do
    case Date.day_of_week(date) do
      1 -> "Lun"
      2 -> "Mar"
      3 -> "Mié"
      4 -> "Jue"
      5 -> "Vie"
      6 -> "Sáb"
      7 -> "Dom"
    end
  end
end
