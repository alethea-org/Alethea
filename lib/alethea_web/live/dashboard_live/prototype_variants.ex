defmodule AletheaWeb.DashboardLive.PrototypeVariants do
  @moduledoc """
  PROTOTYPE — THROWAWAY. Dashboard layout variants for wayfinder ticket
  #116 ("Layout & visual disposition: dashboard + onboarding").

  Three structurally different takes on `/dashboard`, mounted on the real
  route via `?variant=`, so they render against real data, the real app
  shell and real density:

    * `a` — Briefing: one reading column. The weekly pre-session report is
      the hero; patient picking is a chip rail; the bot settings (crisis
      and welcome message) drop to a collapsed section because they are
      professional-scoped, not patient-scoped.
    * `b` — Triage board: the caseload is a full-width sortable-looking
      table with risk, next session and a 7-day sparkline; the patient
      detail opens in a right slide-over.
    * `c` — Week agenda: time first. A Mon–Sun strip slots every patient's
      session; the hero is the briefing for the next session.

  No tests, no error handling, no abstraction — read the variants, pick a
  direction, then delete this module.
  """
  use AletheaWeb, :html

  alias AletheaWeb.DashboardLive.Components.EmotionChart

  @day_names %{
    1 => "Lun",
    2 => "Mar",
    3 => "Mié",
    4 => "Jue",
    5 => "Vie",
    6 => "Sáb",
    7 => "Dom"
  }

  # ── Variant A — Briefing ──────────────────────────────────────────

  def variant_a(assigns) do
    ~H"""
    <div class="pt pta-wrap">
      <p class="pt-eyebrow">Preparación de sesión</p>
      <h1 class="pt-h1" style="margin-bottom:20px;">
        {@current_professional.full_name || "Profesional Clínico"}
      </h1>

      <div class="pta-picker">
        <.link
          :for={patient <- @patients}
          patch={~p"/dashboard/patients/#{patient.id}?variant=a"}
          class={[
            "pta-chip",
            @selected_patient && @selected_patient.id == patient.id && "pta-chip--active",
            patient.urgent_intervention && "pta-chip--risk"
          ]}
        >
          <span class="pt-avatar" style="width:24px; height:24px; font-size:10px;">
            {initials(patient.alias)}
          </span>
          {patient.alias}
        </.link>
      </div>

      <div :if={!@selected_patient} class="pt-card">
        <div class="pt-empty">
          Elegí un paciente arriba para leer su briefing de la semana.
        </div>
      </div>

      <div :if={@selected_patient}>
        <div style="display:flex; align-items:center; justify-content:space-between; gap:12px; margin-bottom:14px;">
          <h2 class="pt-h2">Briefing · {@selected_patient.alias}</h2>
          <span class={"pt-pill " <> mood_pill(@mood_signal)}>{@mood_signal.label}</span>
        </div>

        <article class="pta-briefing">
          <p class="pt-eyebrow" style="margin-bottom:10px;">
            Resumen semanal
            <span :if={@weekly_summary}>· {format_date(@weekly_summary.period_end)}</span>
          </p>
          <p :if={@weekly_summary} class="pta-briefing__text">{@weekly_summary.summary_text}</p>
          <p :if={!@weekly_summary} class="pt-muted" style="font-style:italic;">
            Sin resumen semanal generado todavía.
          </p>
        </article>

        <div class="pta-metrics">
          <div :for={emotion <- @emotion_rows} class="pta-metric">
            <div class="pta-metric__value">{emotion.percent}%</div>
            <div class="pta-metric__label">{emotion.label}</div>
          </div>
          <div :if={@emotion_rows == []} class="pta-metric">
            <div class="pta-metric__value">—</div>
            <div class="pta-metric__label">Sin métricas</div>
          </div>
        </div>

        <div class="pt-card" style="margin-bottom:20px;">
          <div class="pt-card__head">
            <span class="pt-h2">Evolución emocional</span>
            <span class="pt-eyebrow">Últimos 7 días</span>
          </div>
          <div class="pt-card__body">
            <EmotionChart.emotion_chart daily_data={@emotion_chart_data} />
          </div>
        </div>

        <h3 class="pt-h2" style="margin-bottom:14px;">Sesiones anteriores</h3>
        <div :if={@session_summaries == []} class="pt-card">
          <div class="pt-empty">Sin sesiones con seguimiento clínico aún.</div>
        </div>
        <div class="pta-timeline">
          <div :for={summary <- @session_summaries} class="pta-timeline__item">
            <div style="display:flex; align-items:center; gap:8px; margin-bottom:4px;">
              <strong style="font-size:13px;">{format_date(summary.period_end)}</strong>
              <span class={"pt-pill " <> status_pill(summary.status_level)}>
                {summary.status_level}
              </span>
            </div>
            <p class="pt-muted">{summary.summary_text}</p>
          </div>
        </div>

        <div class="pt-card" style="margin-top:20px;">
          <div class="pt-card__head">
            <span class="pt-h2">Sesión y historial</span>
          </div>
          <div
            class="pt-card__body"
            style="display:grid; grid-template-columns:repeat(auto-fit,minmax(240px,1fr)); gap:20px;"
          >
            <.schedule_form patient={@selected_patient} />
            <div>
              <button
                id="decrypt-chat-button"
                type="button"
                phx-click="decrypt_chat"
                class={["pt-btn", @chat_decrypted && "pt-btn--ghost"]}
              >
                {if @chat_decrypted, do: "Chat descifrado", else: "Descifrar chat"}
              </button>
              <.chat_history :if={@chat_decrypted} streams={@streams} />
            </div>
          </div>
        </div>
      </div>

      <details class="pta-settings">
        <summary>Configuración de tu bot (aplica a todos tus pacientes)</summary>
        <div class="pta-settings__grid">
          <.crisis_form professional={@current_professional} />
          <.welcome_form professional={@current_professional} />
        </div>
      </details>
    </div>
    """
  end

  # ── Variant B — Triage board ──────────────────────────────────────

  def variant_b(assigns) do
    ~H"""
    <div class="pt">
      <div class="ptb-toolbar">
        <div>
          <p class="pt-eyebrow">Cartera de pacientes</p>
          <h1 class="pt-h1">Triage</h1>
        </div>
        <div class="ptb-counters">
          <div class="ptb-counter"><strong>{length(@patients)}</strong> en seguimiento</div>
          <div class="ptb-counter"><strong>{length(@critical_patients)}</strong> en alerta</div>
        </div>
      </div>

      <div class="pt-card" style="overflow:hidden;">
        <table class="ptb-table">
          <thead>
            <tr>
              <th>Paciente</th>
              <th>Estado</th>
              <th>Próxima sesión</th>
              <th>Últimos 7 días</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={patient <- @patients}
              id={"ptb-row-#{patient.id}"}
              class={patient.urgent_intervention && "ptb-row--risk"}
            >
              <td>
                <.link patch={~p"/dashboard/patients/#{patient.id}?variant=b"} class="ptb-name">
                  <span class="pt-avatar" style="width:30px; height:30px; font-size:11px;">
                    {initials(patient.alias)}
                  </span>
                  {patient.alias}
                </.link>
              </td>
              <td>
                <span class={"pt-pill " <> if(patient.urgent_intervention, do: "pt-pill--danger", else: "pt-pill--ok")}>
                  {if patient.urgent_intervention, do: "Intervención prioritaria", else: "Estable"}
                </span>
              </td>
              <td style="color:var(--pt-ink-2);">{session_slot(patient)}</td>
              <td><.sparkline seed={patient.alias} /></td>
            </tr>
            <tr :if={@patients == []}>
              <td colspan="4">
                <div class="pt-empty">Sin pacientes todavía.</div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <details class="pt-card" style="margin-top:16px;">
        <summary style="padding:12px 16px; cursor:pointer; font-size:13px; font-weight:600; color:var(--pt-ink-2);">
          Configuración de tu bot (aplica a todos tus pacientes)
        </summary>
        <div
          class="pt-card__body"
          style="display:grid; grid-template-columns:repeat(auto-fit,minmax(280px,1fr)); gap:16px; border-top:1px solid var(--pt-line);"
        >
          <.crisis_form professional={@current_professional} />
          <.welcome_form professional={@current_professional} />
        </div>
      </details>

      <%!-- Slide-over detail --%>
      <aside :if={@selected_patient} class="ptb-drawer">
        <div class="ptb-drawer__head">
          <span class="pt-avatar" style="width:36px; height:36px; font-size:13px;">
            {initials(@selected_patient.alias)}
          </span>
          <div>
            <div class="pt-h2">{@selected_patient.alias}</div>
            <span class={"pt-pill " <> mood_pill(@mood_signal)}>{@mood_signal.label}</span>
          </div>
          <.link patch={~p"/dashboard?variant=b"} class="ptb-drawer__close" aria-label="Cerrar">
            &times;
          </.link>
        </div>

        <div class="ptb-tabs">
          <span class="ptb-tab ptb-tab--active">Semana</span>
        </div>

        <div class="ptb-drawer__body">
          <div class="pt-card" style="margin-bottom:16px;">
            <div class="pt-card__head">
              <span class="pt-h2">Resumen semanal</span>
              <span :if={@weekly_summary} class="pt-eyebrow">
                {format_date(@weekly_summary.period_end)}
              </span>
            </div>
            <div class="pt-card__body">
              <p :if={@weekly_summary} class="pt-muted">{@weekly_summary.summary_text}</p>
              <p :if={!@weekly_summary} class="pt-muted" style="font-style:italic;">
                Sin resumen semanal generado todavía.
              </p>
            </div>
          </div>

          <div class="pt-card" style="margin-bottom:16px;">
            <div class="pt-card__head"><span class="pt-h2">Tendencias</span></div>
            <div class="pt-card__body">
              <div :for={emotion <- @emotion_rows} style="margin-bottom:10px;">
                <div style="display:flex; justify-content:space-between; font-size:12px; font-weight:600; margin-bottom:4px;">
                  <span>{emotion.label}</span>
                  <span style="font-variant-numeric:tabular-nums;">{emotion.percent}%</span>
                </div>
                <progress
                  class={"progress " <> emotion.progress_class}
                  value={emotion.percent}
                  max="100"
                  style="height:6px; width:100%;"
                >
                </progress>
              </div>
              <EmotionChart.emotion_chart daily_data={@emotion_chart_data} />
            </div>
          </div>

          <div class="pt-card" style="margin-bottom:16px;">
            <div class="pt-card__head"><span class="pt-h2">Sesiones</span></div>
            <div class="pt-card__body">
              <details :for={summary <- @session_summaries} style="margin-bottom:8px;">
                <summary style="cursor:pointer; font-size:13px; font-weight:600;">
                  {format_date(summary.period_end)} · {summary.status_level}
                </summary>
                <p class="pt-muted" style="margin-top:6px;">{summary.summary_text}</p>
              </details>
              <div :if={@session_summaries == []} class="pt-empty">Sin sesiones aún.</div>
            </div>
          </div>

          <div class="pt-card" style="margin-bottom:16px;">
            <div class="pt-card__body">
              <.schedule_form patient={@selected_patient} />
            </div>
          </div>

          <div class="pt-card">
            <div class="pt-card__body">
              <button
                id="decrypt-chat-button"
                type="button"
                phx-click="decrypt_chat"
                class={["pt-btn", @chat_decrypted && "pt-btn--ghost"]}
              >
                {if @chat_decrypted, do: "Chat descifrado", else: "Descifrar chat"}
              </button>
              <.chat_history :if={@chat_decrypted} streams={@streams} />
            </div>
          </div>
        </div>
      </aside>
    </div>
    """
  end

  # ── Variant C — Week agenda ───────────────────────────────────────

  def variant_c(assigns) do
    assigns = assign(assigns, :by_day, Enum.group_by(assigns.patients, & &1.session_day_of_week))

    ~H"""
    <div class="pt">
      <p class="pt-eyebrow">Semana clínica</p>
      <h1 class="pt-h1" style="margin-bottom:20px;">Agenda y preparación</h1>

      <div class="ptc-week">
        <div
          :for={day <- 1..7}
          class={["ptc-day", day == @today_day_of_week && "ptc-day--today"]}
        >
          <div class="ptc-day__name">{day_name(day)}</div>
          <.link
            :for={patient <- Map.get(@by_day, day, [])}
            patch={~p"/dashboard/patients/#{patient.id}?variant=c"}
            class={["ptc-slot", patient.urgent_intervention && "ptc-slot--risk"]}
          >
            {patient.alias}
            <small>{format_time(patient.session_time)}</small>
          </.link>
        </div>
      </div>

      <div :if={!@selected_patient} class="pt-card">
        <div class="pt-empty">
          Elegí una sesión de la semana para preparar el encuentro.
        </div>
      </div>

      <div :if={@selected_patient} class="ptc-hero">
        <div class="ptc-next">
          <div class="ptc-next__head">
            <div>
              <div class="pt-eyebrow" style="color:rgba(255,255,255,.7);">Próxima sesión</div>
              <div style="font-size:18px; font-weight:700;">{@selected_patient.alias}</div>
            </div>
            <div style="text-align:right; font-size:13px;">
              {day_name(@selected_patient.session_day_of_week)}
              {format_time(@selected_patient.session_time)}
            </div>
          </div>
          <div class="ptc-next__body">
            <span class={"pt-pill " <> mood_pill(@mood_signal)}>{@mood_signal.label}</span>

            <h3 class="pt-h2" style="margin:16px 0 8px;">Resumen de la semana</h3>
            <p :if={@weekly_summary} class="pt-muted" style="font-size:15px;">
              {@weekly_summary.summary_text}
            </p>
            <p :if={!@weekly_summary} class="pt-muted" style="font-style:italic;">
              Sin resumen semanal generado todavía.
            </p>

            <h3 class="pt-h2" style="margin:22px 0 8px;">Evolución emocional</h3>
            <EmotionChart.emotion_chart daily_data={@emotion_chart_data} />

            <h3 class="pt-h2" style="margin:22px 0 8px;">Sesiones anteriores</h3>
            <details :for={summary <- @session_summaries} style="margin-bottom:8px;">
              <summary style="cursor:pointer; font-size:13px; font-weight:600;">
                {format_date(summary.period_end)} · {summary.status_level}
              </summary>
              <p class="pt-muted" style="margin-top:6px;">{summary.summary_text}</p>
            </details>
            <div :if={@session_summaries == []} class="pt-empty">Sin sesiones aún.</div>
          </div>
        </div>

        <div class="ptc-rail">
          <div class="pt-card">
            <div class="pt-card__head"><span class="pt-h2">Métricas de la semana</span></div>
            <div class="pt-card__body">
              <div
                :for={emotion <- @emotion_rows}
                style="display:flex; justify-content:space-between; padding:6px 0; border-bottom:1px solid var(--pt-line); font-size:13px;"
              >
                <span style="color:var(--pt-ink-2);">{emotion.label}</span>
                <strong style="font-variant-numeric:tabular-nums;">{emotion.percent}%</strong>
              </div>
              <div :if={@emotion_rows == []} class="pt-empty">Sin métricas.</div>
            </div>
          </div>

          <div class="pt-card">
            <div class="pt-card__body">
              <.schedule_form patient={@selected_patient} />
            </div>
          </div>

          <div class="pt-card">
            <div class="pt-card__body">
              <button
                id="decrypt-chat-button"
                type="button"
                phx-click="decrypt_chat"
                class={["pt-btn", @chat_decrypted && "pt-btn--ghost"]}
              >
                {if @chat_decrypted, do: "Chat descifrado", else: "Descifrar chat"}
              </button>
              <.chat_history :if={@chat_decrypted} streams={@streams} />
            </div>
          </div>
        </div>
      </div>

      <details class="pt-card" style="margin-top:24px;">
        <summary style="padding:12px 16px; cursor:pointer; font-size:13px; font-weight:600; color:var(--pt-ink-2);">
          Configuración de tu bot (aplica a todos tus pacientes)
        </summary>
        <div
          class="pt-card__body"
          style="display:grid; grid-template-columns:repeat(auto-fit,minmax(280px,1fr)); gap:16px; border-top:1px solid var(--pt-line);"
        >
          <.crisis_form professional={@current_professional} />
          <.welcome_form professional={@current_professional} />
        </div>
      </details>
    </div>
    """
  end

  # ── Shared bits ───────────────────────────────────────────────────

  attr(:patient, :any, required: true)

  defp schedule_form(assigns) do
    ~H"""
    <.form for={%{}} id="schedule-form" phx-submit="save_session_schedule">
      <p class="pt-eyebrow" style="margin-bottom:10px;">Horario de sesión</p>
      <div class="pt-field">
        <label for="pt-day">Día</label>
        <select id="pt-day" name="day" class="pt-select">
          <option :for={day <- 1..7} value={day} selected={@patient.session_day_of_week == day}>
            {day_full_name(day)}
          </option>
        </select>
      </div>
      <div class="pt-field">
        <label for="pt-time">Hora</label>
        <input
          id="pt-time"
          type="time"
          name="time"
          value={format_time(@patient.session_time)}
          class="pt-input"
        />
      </div>
      <button type="submit" class="pt-btn">Guardar cambios</button>
    </.form>
    """
  end

  attr(:professional, :any, required: true)

  defp crisis_form(assigns) do
    ~H"""
    <.form for={%{}} id="crisis-message-form" phx-submit="save_crisis_message">
      <p class="pt-eyebrow" style="margin-bottom:6px;">Mensaje de contención</p>
      <p class="pt-muted" style="font-size:12px; margin-bottom:8px;">
        Enviado automáticamente cuando la IA detecta una crisis.
      </p>
      <textarea name="crisis_message" rows="4" class="pt-textarea">{@professional.crisis_message}</textarea>
      <button type="submit" class="pt-btn pt-btn--ghost" style="margin-top:8px;">Actualizar</button>
    </.form>
    """
  end

  attr(:professional, :any, required: true)

  defp welcome_form(assigns) do
    ~H"""
    <.form for={%{}} id="welcome-message-form" phx-submit="save_welcome_message">
      <p class="pt-eyebrow" style="margin-bottom:6px;">Mensaje de bienvenida</p>
      <p class="pt-muted" style="font-size:12px; margin-bottom:8px;">
        Enviado al vincular Telegram. Usá {"%{name}"} para incluir el nombre del paciente.
      </p>
      <textarea name="welcome_message" rows="4" class="pt-textarea">{@professional.welcome_message}</textarea>
      <button type="submit" class="pt-btn pt-btn--ghost" style="margin-top:8px;">Actualizar</button>
    </.form>
    """
  end

  attr(:streams, :any, required: true)

  defp chat_history(assigns) do
    ~H"""
    <div
      id="chat-history-panel"
      phx-update="stream"
      style="margin-top:12px; max-height:300px; overflow-y:auto; border:1px solid var(--pt-line); border-radius:10px; background:#fafbfc; padding:8px;"
    >
      <div
        :for={{id, msg} <- @streams.decrypted_messages}
        id={id}
        class={"chat " <> if(msg.direction == "inbound", do: "chat-start", else: "chat-end")}
      >
        <div class="chat-header" style="font-size:9px; color:var(--pt-ink-3);">
          {Calendar.strftime(msg.timestamp, "%H:%M")}
        </div>
        <div
          class={"chat-bubble " <> if(msg.direction == "outbound", do: "chat-bubble-primary", else: "")}
          style="font-size:12px; line-height:1.5;"
        >
          {msg.encrypted_content}
        </div>
      </div>
    </div>
    """
  end

  attr(:seed, :string, required: true)

  defp sparkline(assigns) do
    heights =
      assigns.seed
      |> :erlang.phash2()
      |> Integer.to_string()
      |> String.pad_leading(7, "4")
      |> String.slice(0, 7)
      |> String.graphemes()
      |> Enum.map(&(String.to_integer(&1) * 2 + 6))

    assigns = assign(assigns, :heights, heights)

    ~H"""
    <span class="ptb-spark">
      <i :for={height <- @heights} style={"height:#{height}px;"}></i>
    </span>
    """
  end

  # ── Formatting ────────────────────────────────────────────────────

  defp initials(alias_name) do
    alias_name
    |> String.split()
    |> Enum.map(&String.first/1)
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end

  defp format_date(%DateTime{} = date_time), do: Calendar.strftime(date_time, "%d/%m/%Y")
  defp format_date(_), do: "-"

  defp format_time(%Time{} = time), do: Calendar.strftime(time, "%H:%M")
  defp format_time(_), do: "-"

  defp day_name(day), do: Map.get(@day_names, day, "—")

  defp day_full_name(day) do
    %{
      1 => "Lunes",
      2 => "Martes",
      3 => "Miércoles",
      4 => "Jueves",
      5 => "Viernes",
      6 => "Sábado",
      7 => "Domingo"
    }
    |> Map.get(day, "—")
  end

  defp session_slot(patient) do
    case patient.session_day_of_week do
      nil -> "Sin agendar"
      day -> "#{day_name(day)} #{format_time(patient.session_time)}"
    end
  end

  defp mood_pill(%{label: "Estable"}), do: "pt-pill--ok"
  defp mood_pill(%{label: "Alerta"}), do: "pt-pill--warn"
  defp mood_pill(%{label: "Crítico"}), do: "pt-pill--danger"
  defp mood_pill(_), do: "pt-pill--neutral"

  defp status_pill("Estable"), do: "pt-pill--ok"
  defp status_pill("Alerta"), do: "pt-pill--warn"
  defp status_pill("Crítico"), do: "pt-pill--danger"
  defp status_pill(_), do: "pt-pill--neutral"
end
