defmodule AletheaWeb.LoginLive do
  @moduledoc """
  LiveView login screen.

  Not reachable from `AletheaWeb.Router` — `GET /login` is served by
  `AletheaWeb.SessionController`. It is restyled here so no surface in
  the tree carries the old chrome, but it should be deleted rather
  than kept in parallel with the controller-based page.
  """
  use Phoenix.LiveView

  import Phoenix.LiveView
  import Phoenix.Component

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Iniciar sesión")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="auth-layout">
      <section class="auth-panel">
        <span class="auth-panel__brand">Alethea</span>
        <div>
          <h2 class="auth-panel__title">La semana del paciente, ya leída.</h2>

          <p class="auth-panel__lede">El registro diario entre sesiones llega convertido en un resumen
            clínico con métricas y tendencias.</p>
        </div>

        <p class="auth-panel__proof">
          Cada paciente tiene su propia clave de cifrado. Ni el equipo de Alethea
          ni terceros pueden leer el contenido clínico.
        </p>
      </section>

      <section class="auth-form-side">
        <div id="login-page" class="auth-form">
          <p class="pt-eyebrow">Centro de Control Clínico</p>

          <h1 class="auth-form__title">Iniciar sesión</h1>

          <p class="auth-form__sub">Ingresá tus credenciales para continuar.</p>

          <div :if={@flash["error"]} class="notice notice--error"><span>{@flash["error"]}</span></div>

          <.form for={%{}} as={:professional} phx-submit="login" id="login-form">
            <div class="field">
              <label for="email" class="field__label">Correo electrónico</label>
              <input
                type="email"
                name="professional[email]"
                id="email"
                required
                placeholder="tu@email.com"
                autocomplete="email"
                class="text-input"
              />
            </div>

            <div class="field">
              <label for="password" class="field__label">Contraseña</label>
              <input
                type="password"
                name="professional[password]"
                id="password"
                required
                placeholder="••••••••"
                autocomplete="current-password"
                class="text-input"
              />
            </div>
            <button type="submit" class="button-primary button-primary--block">Ingresar</button>
          </.form>

          <p class="auth-form__foot">¿No tenés cuenta? <a href="/register">Registrate acá</a></p>

          <p class="auth-form__note">Cifrado a nivel de paciente</p>
        </div>
      </section>
    </div>
    """
  end

  @impl true
  def handle_event(
        "login",
        %{"professional" => %{"email" => email, "password" => password}},
        socket
      ) do
    case Alethea.Accounts.authenticate_professional(email, password) do
      {:ok, professional} ->
        {:noreply,
         push_navigate(socket, to: "/login/set_session?professional_id=#{professional.id}")}

      {:error, :invalid_credentials} ->
        {:noreply, put_flash(socket, :error, "Correo o contraseña incorrectos.")}
    end
  end
end
