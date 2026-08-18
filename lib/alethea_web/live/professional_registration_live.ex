defmodule AletheaWeb.ProfessionalRegistrationLive do
  @moduledoc """
  LiveView registration screen.

  Not reachable from `AletheaWeb.Router` — `GET /register` is served
  by `AletheaWeb.RegistrationController`. It is restyled here so no
  surface in the tree carries the old chrome, but it should be
  deleted rather than kept in parallel with the controller-based page.
  """
  use Phoenix.LiveView

  import Phoenix.Component

  alias Alethea.Accounts
  alias Alethea.Accounts.Professional

  @impl true
  def mount(_params, _session, socket) do
    changeset = Professional.changeset(%Professional{}, %{})
    {:ok, assign(socket, page_title: "Registrar cuenta", changeset: changeset)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="auth-layout">
      <section class="auth-panel">
        <span class="auth-panel__brand">Alethea</span>
        <div>
          <h2 class="auth-panel__title">Una cuenta, todo el seguimiento.</h2>

          <p class="auth-panel__lede">
            Invitás al paciente por Telegram, la conversación se cifra con su
            propia clave y vos leés el resumen semanal antes de la sesión.
          </p>
        </div>

        <p class="auth-panel__proof">
          El borrado de datos es criptográfico: se destruye la clave del paciente
          en la bóveda, no se borran filas.
        </p>
      </section>

      <section class="auth-form-side">
        <div id="register-page" class="auth-form">
          <p class="pt-eyebrow">Cuenta profesional</p>

          <h1 class="auth-form__title">Registrar cuenta</h1>

          <p class="auth-form__sub">Completá los datos para acceder a Alethea.</p>

          <.form
            for={@changeset}
            phx-submit="save"
            phx-change="validate"
            id="registration-form"
          >
            <div class="field">
              <label for="email" class="field__label">Correo electrónico</label>
              <input
                type="email"
                name="professional[email]"
                id="email"
                required
                placeholder="tu@email.com"
                autocomplete="email"
                value={Ecto.Changeset.get_field(@changeset, :email)}
                class="text-input"
              />
              <p :for={{msg, _} <- Keyword.get_values(@changeset.errors, :email)} class="field__error">
                {msg}
              </p>
            </div>

            <div class="field">
              <label for="full_name" class="field__label">Nombre completo</label>
              <input
                type="text"
                name="professional[full_name]"
                id="full_name"
                required
                placeholder="Tu nombre"
                autocomplete="name"
                value={Ecto.Changeset.get_field(@changeset, :full_name)}
                class="text-input"
              />
              <p
                :for={{msg, _} <- Keyword.get_values(@changeset.errors, :full_name)}
                class="field__error"
              >
                {msg}
              </p>
            </div>

            <div class="field">
              <label for="password" class="field__label">Contraseña</label>
              <input
                type="password"
                name="professional[password]"
                id="password"
                required
                placeholder="••••••••"
                autocomplete="new-password"
                class="text-input"
              />
              <p class="field__hint">La contraseña debe tener al menos 12 caracteres.</p>

              <p
                :for={{msg, _} <- Keyword.get_values(@changeset.errors, :password)}
                class="field__error"
              >
                {msg}
              </p>
            </div>
            <button type="submit" class="button-primary button-primary--block">Crear cuenta</button>
          </.form>

          <p class="auth-form__foot">¿Ya tenés cuenta? <a href="/login">Iniciá sesión</a></p>

          <p class="auth-form__note">Cifrado a nivel de paciente</p>
        </div>
      </section>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"professional" => params}, socket) do
    changeset = Professional.changeset(%Professional{}, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, changeset: changeset)}
  end

  @impl true
  def handle_event("save", %{"professional" => params}, socket) do
    case Accounts.create_professional(params) do
      {:ok, _professional} ->
        {:noreply,
         put_flash(socket, :info, "Cuenta creada con éxito. Ahora podés iniciar sesión.")
         |> push_navigate(to: "/login")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end
end
