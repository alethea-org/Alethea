defmodule AletheaWeb.DashboardLive do
  use AletheaWeb, :live_view
  import Ecto.Query
  require Logger
  alias Alethea.Accounts
  alias Alethea.Clinical.{MockData, Message}
  alias AletheaWeb.DashboardLive.Components.EmotionChart
  alias Alethea.Encryption.PatientVault
  alias AletheaWeb.DashboardLive.Components.NotificationCenter
  alias Alethea.Foundation.Accounts, as: FoundationAccounts
  alias Alethea.Foundation.Accounts.BotConfig

  def mount(_params, %{"professional_id" => id}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Alethea.PubSub, "crisis:alerts")
      Phoenix.PubSub.subscribe(Alethea.PubSub, "psychologist:alerts")
      Phoenix.PubSub.subscribe(Alethea.PubSub, "patients:#{id}")
    end

    professional = Accounts.get_professional!(id)
    use_mock? = Application.get_env(:alethea, :use_mock_data, false)

    patients =
      if use_mock?,
        do: MockData.list_mock_patients(professional.id),
        else: Accounts.list_patients(professional.id)

    critical_patients =
      if use_mock?,
        do: Enum.filter(patients, & &1.urgent_intervention),
        else: Accounts.list_critical_patients(professional.id)

    socket =
      socket
      |> assign(:current_professional, professional)
      |> assign(:page_title, "Centro de Control")
      |> assign(:use_mock_data, use_mock?)
      |> assign(:patients, patients)
      |> assign(:critical_patients, critical_patients)
      |> assign(:selected_patient, nil)
      |> assign(:weekly_summary, nil)
      |> assign(:session_summaries, [])
      |> assign(:emotion_rows, [])
      |> assign(:emotion_chart_data, [])
      |> assign(:mood_signal, default_mood_signal())
      |> assign(
        :today_day_of_week,
        DateTime.utc_now() |> DateTime.to_date() |> Date.day_of_week()
      )
      |> assign(:chat_decrypted, false)

    # Telegram invite wiring (feature: patient telegram invites).
    # Real mode resolves the foundation professional once per session
    # (email bridge, D1) and derives the per-patient connection statuses
    # in a single batch query (no N+1). Mock mode short-circuits both
    # and never touches the foundation tenant (D5).
    foundation_pro =
      if use_mock? do
        nil
      else
        case FoundationAccounts.professional_by_email(professional.email) do
          {:ok, fp} -> fp
          :not_found -> nil
        end
      end

    telegram_statuses =
      if use_mock? or is_nil(foundation_pro) do
        %{}
      else
        FoundationAccounts.telegram_connection_statuses(
          Enum.map(patients, & &1.id),
          foundation_pro
        )
      end

    socket =
      socket
      |> assign(:foundation_professional, foundation_pro)
      |> assign(:telegram_statuses, telegram_statuses)
      |> assign(:invited_ids, MapSet.new())
      |> assign(:invite_panel, nil)
      |> stream(:decrypted_messages, [])

    {:ok, socket}
  end

  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    socket
    |> assign(:picker, picker_from_params(params))
    |> assign(:by_day, by_day(socket.assigns.patients))
    |> assign(:selected_patient, nil)
    |> assign(:chat_decrypted, false)
    |> stream(:decrypted_messages, [], reset: true)
  end

  defp apply_action(socket, :show, %{"id" => id} = params) do
    patient = find_patient(socket, id)

    if patient do
      # Auditoría de visualización de perfil (solo en modo real, IDs de mock no son UUIDs válidos)
      if is_valid_uuid?(id) do
        Accounts.log_action(%{
          action: "VIEW_PATIENT_PROFILE",
          resource_type: "Patient",
          resource_id: patient.id,
          professional_id: socket.assigns.current_professional.id
        })
      end

      socket
      |> assign(:picker, picker_from_params(params))
      |> assign(:by_day, by_day(socket.assigns.patients))
      |> assign(:chat_decrypted, false)
      |> stream(:decrypted_messages, [], reset: true)
      |> load_patient_details(patient)
    else
      socket
      |> put_flash(:error, "Paciente no encontrado o no autorizado.")
      |> push_patch(to: ~p"/dashboard")
    end
  end

  def handle_event("decrypt_chat", _params, socket) do
    patient = socket.assigns.selected_patient

    {decrypted_messages, audit_result, message_count} =
      if socket.assigns.use_mock_data do
        # Mock mode - no real decryption; the :professional_kek assign is
        # only set by the real-mode mount path, so we short-circuit before
        # touching it.
        messages =
          MockData.list_mock_messages(patient.id)
          |> Enum.map(fn msg ->
            %{msg | encrypted_content: "CONTENIDO DESCIFRADO (MOCK): " <> msg.encrypted_content}
          end)

        {messages, :mock_success, length(messages)}
      else
        # Real decryption attempt
        case decrypt_real_messages(patient, socket.assigns.professional_kek) do
          {:ok, messages} ->
            {messages, :success, length(messages)}

          {:error, reason} ->
            {[], {:error, reason}, 0}
        end
      end

    # Log audit (for both mock and real mode)
    log_decrypt_audit(socket, patient, audit_result, message_count)

    socket =
      socket
      |> assign(:chat_decrypted, true)
      |> stream(:decrypted_messages, decrypted_messages, reset: true)

    {:noreply, socket}
  end

  def handle_event("save_session_schedule", %{"day" => day, "time" => time}, socket) do
    patient = socket.assigns.selected_patient
    day = String.to_integer(day)
    time = Time.from_iso8601!(time <> ":00")

    if socket.assigns.use_mock_data do
      # En modo mock actualizamos solo en memoria (el id no es un UUID válido)
      updated_patient = %{patient | session_day_of_week: day, session_time: time}

      patients =
        socket.assigns.patients
        |> Enum.map(fn p -> if p.id == patient.id, do: updated_patient, else: p end)

      socket =
        socket
        |> put_flash(:info, "Horario de sesión actualizado correctamente.")
        |> assign(:selected_patient, updated_patient)
        |> assign(:patients, patients)

      {:noreply, socket}
    else
      case Accounts.update_patient_session_schedule(patient, day, time) do
        {:ok, updated_patient} ->
          try do
            AletheaJobs.SessionReminderWorker.cancel_pending(updated_patient.id)
          rescue
            error ->
              Logger.warning(
                "save_session_schedule: reminder cancel failed " <>
                  "(patient_id=#{updated_patient.id}, reason=#{inspect(error)})"
              )
          end

          patients = Accounts.list_patients(socket.assigns.current_professional.id)

          socket =
            socket
            |> put_flash(:info, "Horario de sesión actualizado correctamente.")
            |> assign(:selected_patient, updated_patient)
            |> assign(:patients, patients)

          {:noreply, socket}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "No se pudo actualizar el horario.")}
      end
    end
  end

  def handle_event("save_crisis_message", %{"crisis_message" => message}, socket) do
    professional = socket.assigns.current_professional

    case Accounts.update_professional(professional, %{crisis_message: message}) do
      {:ok, updated_professional} ->
        socket =
          socket
          |> put_flash(:info, "Mensaje de contención actualizado.")
          |> assign(:current_professional, updated_professional)

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Error al guardar el mensaje.")}
    end
  end

  def handle_event("save_welcome_message", %{"welcome_message" => message}, socket) do
    professional = socket.assigns.current_professional

    case Accounts.update_professional(professional, %{welcome_message: message}) do
      {:ok, updated_professional} ->
        socket =
          socket
          |> put_flash(:info, "Mensaje de bienvenida actualizado.")
          |> assign(:current_professional, updated_professional)

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Error al guardar el mensaje.")}
    end
  end

  # Telegram invite flow (feature: patient telegram invites). Both the
  # header button and the sidebar row buttons (which bubble up from the
  # PatientSearch LiveComponent, since it does not handle this event)
  # land here. Regenerate refreshes the panel with a fresh pair of
  # codes in real mode; mock mode reuses the static payload (D5).
  def handle_event("invite_patient", %{"id" => patient_id}, socket) do
    invite_patient_to_telegram(socket, patient_id)
  end

  def handle_event("regenerate_invite", %{"id" => patient_id}, socket) do
    invite_patient_to_telegram(socket, patient_id)
  end

  def handle_event("dismiss_invite", _params, socket) do
    {:noreply, assign(socket, :invite_panel, nil)}
  end

  defp decrypt_real_messages(patient, professional_kek) do
    key_record = Accounts.get_encryption_key_for_patient(patient.id)

    with {:ok, dek_bytes} <- PatientVault.decrypt(key_record.encrypted_key, professional_kek) do
      # Cargar últimos 50 mensajes
      messages =
        Alethea.Repo.all(
          from(m in Message,
            where: m.patient_id == ^patient.id,
            order_by: [desc: m.timestamp],
            limit: 50
          )
        )

      # Descifrar contenido
      decrypted =
        Enum.map(messages, fn msg ->
          case PatientVault.decrypt(msg.encrypted_content, dek_bytes) do
            {:ok, plain_text} -> %{msg | encrypted_content: plain_text}
            _ -> %{msg | encrypted_content: "[Error al descifrar]"}
          end
        end)

      {:ok, decrypted}
    end
  end

  # --- Telegram invite flow (feature: patient telegram invites) ---
  #
  # Real mode delegates to the domain `invite_patient_to_telegram/2`,
  # which mints both the deep-link token and the 6-digit code (D4/D6).
  # Mock mode short-circuits to a static payload and never touches the
  # DB (D5). The web layer composes the deep link URL from the BotConfig
  # bot_username; the domain returns only the token (D6).
  defp invite_patient_to_telegram(socket, patient_id) do
    patient = find_patient(socket, patient_id)

    if is_nil(patient) do
      {:noreply, put_flash(socket, :error, "Paciente no encontrado o no autorizado.")}
    else
      socket =
        if socket.assigns.use_mock_data do
          show_invite_panel(socket, patient, MockData.mock_invite_payload(patient))
        else
          case foundation_professional_for_invite(socket) do
            {:ok, foundation_pro} ->
              case FoundationAccounts.invite_patient_to_telegram(patient.id, foundation_pro) do
                {:ok, %{deep_link_token: token, six_digit_code: code, expires_at: expires_at}} ->
                  socket
                  |> assign(:foundation_professional, foundation_pro)
                  |> show_invite_panel(patient, %{
                    deep_link_token: token,
                    six_digit_code: code,
                    expires_at: expires_at
                  })

                {:error, :legacy_not_found} ->
                  put_flash(socket, :error, "No se pudo generar la invitación.")

                {:error, _changeset} ->
                  put_flash(socket, :error, "No se pudo generar la invitación.")
              end

            {:error, _changeset} ->
              put_flash(socket, :error, "No se pudo generar la invitación.")
          end
        end

      {:noreply, socket}
    end
  end

  defp foundation_professional_for_invite(socket) do
    case socket.assigns.foundation_professional do
      nil ->
        FoundationAccounts.find_or_provision_foundation_professional(
          socket.assigns.current_professional
        )

      foundation_pro ->
        {:ok, foundation_pro}
    end
  end

  # Both the mock and real branches converge here: the panel state is a
  # plain map and the template renders whatever the caller supplied.
  defp show_invite_panel(socket, patient, %{
         deep_link_token: token,
         six_digit_code: code,
         expires_at: expires_at
       }) do
    socket
    |> assign(
      :invite_panel,
      %{
        patient_id: patient.id,
        patient_alias: patient.alias,
        deep_link: telegram_deep_link(token),
        six_digit_code: code,
        expires_at: expires_at
      }
    )
    |> assign(:invited_ids, MapSet.put(socket.assigns.invited_ids, patient.id))
  end

  # D6: the web layer composes the deep link from the BotConfig
  # bot_username (test/dev/prod env row). Missing config -> nil, and
  # the panel then shows the 6-digit code only.
  defp telegram_deep_link(token) when is_binary(token) do
    case BotConfig.for_env(to_string(Mix.env())) do
      {:ok, %BotConfig{bot_username: username}} when is_binary(username) and username != "" ->
        "https://t.me/#{username}?start=#{token}"

      _ ->
        nil
    end
  end

  # --- Template helpers for the Telegram invite UI ---

  defp tg_status(statuses, patient_id), do: Map.get(statuses, patient_id, :not_connected)

  defp tg_status_label(statuses, patient_id) do
    case tg_status(statuses, patient_id) do
      :connected -> "Conectado"
      _ -> "Sin conectar"
    end
  end

  defp tg_status_class(statuses, patient_id) do
    case tg_status(statuses, patient_id) do
      :connected -> "badge badge-success"
      _ -> "badge badge-ghost"
    end
  end

  defp tg_button_label(statuses, patient_id, invited_ids) do
    case tg_status(statuses, patient_id) do
      :connected -> "Conectado"
      _ -> if MapSet.member?(invited_ids, patient_id), do: "Regenerar", else: "Invitar"
    end
  end

  defp tg_button_event(statuses, patient_id, invited_ids) do
    case tg_status(statuses, patient_id) do
      :connected ->
        nil

      _ ->
        if MapSet.member?(invited_ids, patient_id),
          do: "regenerate_invite",
          else: "invite_patient"
    end
  end

  defp find_patient(socket, id) do
    if socket.assigns.use_mock_data do
      Enum.find(socket.assigns.patients, &(&1.id == id))
    else
      Accounts.get_patient_for_professional(socket.assigns.current_professional.id, id)
    end
  end

  defp load_patient_details(socket, patient) do
    use_mock? = socket.assigns.use_mock_data

    # Weekly summary
    weekly_summary =
      if use_mock? do
        List.first(MockData.list_mock_summaries(patient.id, "weekly"))
      else
        Alethea.Clinical.latest_weekly_summary(patient.id)
      end

    # Session summaries (last 30 days)
    session_summaries =
      if use_mock? do
        MockData.list_mock_summaries(patient.id, "session")
      else
        Alethea.Clinical.list_session_summaries(
          patient.id,
          DateTime.utc_now() |> DateTime.add(-30, :day)
        )
        |> Enum.filter(&(&1.type == "session"))
        |> Enum.sort_by(& &1.period_end, {:desc, Date})
      end

    # Trends (last 7 days)
    trends =
      if use_mock? do
        MockData.list_mock_trends(patient.id)
      else
        now = DateTime.utc_now()
        seven_days_ago = DateTime.add(now, -7, :day)

        Alethea.Clinical.aggregate_trends(patient.id, seven_days_ago)
      end

    emotion_rows = format_emotion_trends(trends)

    emotion_chart_data =
      if use_mock? do
        MockData.list_mock_daily_emotions(patient.id)
      else
        seven_days_ago = DateTime.utc_now() |> DateTime.add(-7, :day)
        Alethea.Clinical.list_daily_emotion_scores(patient.id, seven_days_ago)
      end

    socket
    |> assign(:selected_patient, patient)
    |> assign(:weekly_summary, weekly_summary)
    |> assign(:session_summaries, session_summaries)
    |> assign(:emotion_rows, emotion_rows)
    |> assign(:emotion_chart_data, emotion_chart_data)
    |> assign(:mood_signal, calculate_mood_signal(trends, patient))
  end

  def handle_info({:crisis_detected, %{patient_id: patient_id, level: level}}, socket) do
    professional = socket.assigns.current_professional

    patient =
      if is_valid_uuid?(patient_id) do
        Accounts.get_patient_for_professional(professional.id, patient_id)
      else
        Enum.find(socket.assigns.patients, &(&1.id == patient_id))
      end

    case patient do
      nil ->
        {:noreply, socket}

      patient ->
        patient = %{patient | urgent_intervention: true}

        notif =
          NotificationCenter.build_notification(:crisis_detected, %{
            patient_id: patient_id,
            patient_alias: patient.alias,
            level: level
          })

        Phoenix.LiveView.send_update(NotificationCenter,
          id: "notification-center",
          new_notification: notif
        )

        socket =
          socket
          |> put_flash(
            :error,
            "Alerta Critica: El paciente #{patient.alias} ha entrado en crisis (Nivel: #{level})"
          )
          |> assign(
            :critical_patients,
            upsert_critical_patient(socket.assigns.critical_patients, patient)
          )
          |> assign(:patients, upsert_dashboard_patient(socket.assigns.patients, patient))

        {:noreply, socket}
    end
  end

  def handle_info({:patient_created, patient}, socket) do
    if patient.professional_id == socket.assigns.current_professional.id do
      patients = Accounts.list_patients(socket.assigns.current_professional.id)
      critical_patients = Accounts.list_critical_patients(socket.assigns.current_professional.id)

      notif =
        NotificationCenter.build_notification(:patient_created, %{
          patient_id: patient.id,
          patient_alias: patient.alias
        })

      Phoenix.LiveView.send_update(NotificationCenter,
        id: "notification-center",
        new_notification: notif
      )

      {:noreply,
       socket
       |> assign(:patients, patients)
       |> assign(:critical_patients, critical_patients)
       |> put_flash(:info, "Nuevo paciente registrado: #{patient.alias}")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:emotion_trends_updated, patient_id}, socket) do
    case socket.assigns.selected_patient do
      %{id: ^patient_id} = patient ->
        {:noreply, load_patient_details(socket, patient)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp upsert_critical_patient(patients, patient) do
    patients
    |> reject_patient(patient.id)
    |> then(&[patient | &1])
  end

  defp upsert_dashboard_patient(patients, patient) do
    patients
    |> reject_patient(patient.id)
    |> then(&[patient | &1])
    |> Enum.sort_by(&{not &1.urgent_intervention, String.downcase(&1.alias || "")})
  end

  defp reject_patient(patients, patient_id) do
    Enum.reject(patients, &(&1.id == patient_id))
  end

  defp format_emotion_trends(trends) do
    trends
    |> Enum.map(fn trend ->
      # Handle both mock format (indicator_name/score) and aggregate format (label/score)
      key = Map.get(trend, :indicator_name) || Map.get(trend, :label)

      %{
        key: key,
        label: format_emotion_label(key),
        percent: round((Map.get(trend, :score) || 0) * 100),
        percent_label: format_trend_percentage(Map.get(trend, :score)),
        progress_class: emotion_progress_class(key)
      }
    end)
    |> Enum.sort_by(& &1.percent, :desc)
  end

  defp format_emotion_label("joy"), do: "Alegría"
  defp format_emotion_label("sadness"), do: "Tristeza"
  defp format_emotion_label("anger"), do: "Ira"
  defp format_emotion_label("fear"), do: "Miedo"
  defp format_emotion_label("neutral"), do: "Neutro"
  defp format_emotion_label(other), do: String.capitalize(other)

  defp format_trend_percentage(score) when is_number(score) do
    percent = round(score * 100)

    if score > 0 and percent == 0 do
      "<1%"
    else
      "#{percent}%"
    end
  end

  defp format_trend_percentage(_), do: "0%"

  defp emotion_progress_class("joy"), do: "progress-success"
  defp emotion_progress_class("sadness"), do: "progress-info"
  defp emotion_progress_class("anger"), do: "progress-error"
  defp emotion_progress_class("fear"), do: "progress-warning"
  defp emotion_progress_class("neutral"), do: "progress-ghost"
  defp emotion_progress_class(_), do: ""

  defp calculate_mood_signal(trends, patient) do
    predominant =
      trends
      |> Enum.max_by(&(&1.score || 0), fn -> nil end)
      |> case do
        nil -> nil
        trend -> Map.get(trend, :indicator_name) || Map.get(trend, :label)
      end

    cond do
      patient.urgent_intervention or predominant == "anger" ->
        %{
          label:
            if(patient.urgent_intervention,
              do: "Intervención prioritaria",
              else: "Riesgo: Ira alta"
            ),
          dot_class: "background:#ef4444;",
          badge_class: "badge-error"
        }

      predominant in ["sadness", "fear"] ->
        %{
          label: "Atención: #{format_emotion_label(predominant)}",
          dot_class: "background:#f59e0b;",
          badge_class: "badge-warning"
        }

      true ->
        %{
          label: "Estable",
          dot_class: "background:#22c55e;",
          badge_class: "badge-success"
        }
    end
  end

  defp default_mood_signal do
    %{
      label: "Sin datos",
      dot_class: "background:#cbd5e1;",
      badge_class: "badge-ghost"
    }
  end

  defp format_session_time(%Time{} = time) do
    Calendar.strftime(time, "%H:%M")
  end

  defp format_session_time(_), do: "-"

  defp format_summary_date(%DateTime{} = date_time) do
    Calendar.strftime(date_time, "%d/%m/%Y")
  end

  defp format_summary_date(_), do: "-"

  # El reporte semanal guarda scores 0.0-1.0 y contadores enteros, todos
  # nullable: el chain los deja en nil cuando el LLM no devuelve JSON válido.
  # Un dato ausente se muestra como guión para no romper la grilla de métricas.
  defp format_score(value) when is_number(value), do: "#{round(value * 100)}%"
  defp format_score(_), do: "—"

  defp format_count(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  defp format_count(_), do: "—"

  defp weekly_metrics?(%{
         anxiety_score: anxiety,
         social_score: social,
         crisis_events: crisis,
         session_count: sessions
       }) do
    Enum.any?([anxiety, social, crisis, sessions], &is_number/1)
  end

  defp weekly_metrics?(_), do: false

  # El nivel de estado no está validado en el schema y llega desde varias
  # fuentes (chain semanal, worker de sesión, seeds), así que se normaliza sin
  # acentos ni mayúsculas antes de mapearlo a un tono.
  defp status_tone(%{status_level: level}), do: status_tone(level)

  defp status_tone(level) when is_binary(level) do
    normalized =
      level
      |> String.downcase()
      |> :unicode.characters_to_nfd_binary()
      |> String.replace(~r/[^a-z ]/u, "")

    cond do
      String.contains?(normalized, "intervencion") -> "critical"
      String.contains?(normalized, "critico") -> "critical"
      String.contains?(normalized, "alerta") -> "warning"
      String.contains?(normalized, "stable") -> "stable"
      true -> "neutral"
    end
  end

  defp status_tone(_), do: "neutral"

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true

  defp metric_tile(assigns) do
    ~H"""
    <div id={@id} style="text-align:center;">
      <div style="font-size:9px; font-weight:700; text-transform:uppercase; letter-spacing:0.06em; color:#94a3b8; margin-bottom:2px;">
        {@label}
      </div>
      <div style="font-size:20px; font-weight:700; color:#1e293b; font-variant-numeric:tabular-nums; line-height:1.2;">
        {@value}
      </div>
    </div>
    """
  end

  # Registra auditoría cuando el profesional descifra el historial de chat.
  defp log_decrypt_audit(socket, patient, result, message_count) do
    try do
      Accounts.log_action(%{
        action: "CHAT_DECRYPT",
        professional_id: socket.assigns.current_professional.id,
        resource_type: "Patient",
        resource_id: patient.id,
        details: %{
          result: result,
          message_count: message_count
        }
      })
    rescue
      _ -> :ok
    end
  end

  defp is_valid_uuid?(id) do
    match?({:ok, _}, Ecto.UUID.cast(id))
  end

  # ── Editorial picker helpers (#116) ────────────────────────────────
  #
  # The editorial dashboard carries a `?picker=chips|week` URL param
  # that toggles between a chip rail (with the patient search
  # component) and a Mon–Sun agenda. The helpers below are tiny,
  # view-layer only — no domain logic.

  defp picker_from_params(%{"picker" => "week"}), do: "week"
  defp picker_from_params(_), do: "chips"

  defp by_day(patients) do
    Enum.group_by(patients, & &1.session_day_of_week)
  end

  defp initials(alias_name) when is_binary(alias_name) do
    alias_name
    |> String.split()
    |> Enum.map(&String.first/1)
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end

  defp initials(_), do: "—"

  @day_options [
    {1, "Lunes"},
    {2, "Martes"},
    {3, "Miércoles"},
    {4, "Jueves"},
    {5, "Viernes"},
    {6, "Sábado"},
    {7, "Domingo"}
  ]
  defp day_options, do: @day_options

  @day_short_names %{
    1 => "Lun",
    2 => "Mar",
    3 => "Mié",
    4 => "Jue",
    5 => "Vie",
    6 => "Sáb",
    7 => "Dom"
  }
  defp day_name(day), do: Map.get(@day_short_names, day, "—")

  defp format_time(%Time{} = time), do: Calendar.strftime(time, "%H:%M")
  defp format_time(_), do: "—"

  # Mood / status pill classes — the editorial CSS expects
  # `pt-pill pt-pill--ok|warn|danger|neutral`. Map the existing
  # domain signals onto them.

  defp mood_pill(%{label: "Estable"}), do: "pt-pill--ok"
  defp mood_pill(%{label: "Alerta"}), do: "pt-pill--warn"
  defp mood_pill(%{label: "Crítico"}), do: "pt-pill--danger"
  defp mood_pill(_), do: "pt-pill--neutral"

  defp status_pill("Estable"), do: "pt-pill--ok"
  defp status_pill("Alerta"), do: "pt-pill--warn"
  defp status_pill("Crítico"), do: "pt-pill--danger"
  defp status_pill(_), do: "pt-pill--neutral"

  # Picker toggle patches — preserve the picker when switching
  # between chips and week, and the patient id when one is active.
  defp picker_path(nil, picker) do
    ~p"/dashboard?picker=#{picker}"
  end

  defp picker_path(%{id: id}, picker) do
    ~p"/dashboard/patients/#{id}?picker=#{picker}"
  end
end
