defmodule AletheaWeb.ProfessionalRegistrationLive do
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
    <div
      id="auth-layout"
      style="min-height:100vh; display:flex; align-items:center; justify-content:center; background:linear-gradient(135deg, #f8fafc 0%, #eef2ff 100%); padding:20px;"
    >
      <div id="register-page" style="width:100%; max-width:400px;">
        <%!-- Brand header --%>
        <div style="text-align:center; margin-bottom:32px;">
          <div style="display:inline-flex; align-items:center; justify-content:center; width:56px; height:56px; background:linear-gradient(135deg, #6366f1, #818cf8); border-radius:16px; box-shadow:0 4px 14px rgba(99,102,241,.3); margin-bottom:16px;">
            <svg
              width="28"
              height="28"
              viewBox="0 0 24 24"
              fill="none"
              stroke="#fff"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M12 2L2 7l10 5 10-5-10-5z" />
              <path d="M2 17l10 5 10-5" />
              <path d="M2 12l10 5 10-5" />
            </svg>
          </div>
          <h1 style="font-size:24px; font-weight:800; color:#1e293b; letter-spacing:-0.02em; margin-bottom:4px;">
            Alethea
          </h1>
          <p style="font-size:13px; color:#64748b;">Centro de Control Clínico</p>
        </div>

        <%!-- Register card --%>
        <div style="background:#fff; border-radius:20px; padding:32px; box-shadow:0 4px 24px rgba(0,0,0,.06), 0 1px 2px rgba(0,0,0,.04); border:1px solid rgba(226,232,240,.8);">
          <h2 style="font-size:17px; font-weight:700; color:#1e293b; margin-bottom:24px; text-align:center;">
            Registrar cuenta
          </h2>

          <.form
            for={@changeset}
            phx-submit="save"
            phx-change="validate"
            style="display:flex; flex-direction:column; gap:20px;"
            id="registration-form"
          >
            <%!-- Email field --%>
            <div>
              <label
                for="email"
                style="display:block; font-size:12px; font-weight:600; color:#475569; margin-bottom:6px;"
              >
                Correo electrónico
              </label>
              <input
                type="email"
                name="professional[email]"
                id="email"
                required
                placeholder="tu@email.com"
                autocomplete="email"
                value={Ecto.Changeset.get_field(@changeset, :email)}
                style="width:100%; padding:10px 14px; border:1.5px solid #e2e8f0; border-radius:12px; font-size:14px; color:#1e293b; background:#fff; outline:none;"
              />
              <p
                :for={error <- Keyword.get_values(@changeset.errors, :email)}
                style="margin-top:4px; font-size:11px; color:#dc2626;"
              >
                {elem(error, 0)}
              </p>
            </div>

            <%!-- Full name field --%>
            <div>
              <label
                for="full_name"
                style="display:block; font-size:12px; font-weight:600; color:#475569; margin-bottom:6px;"
              >
                Nombre completo
              </label>
              <input
                type="text"
                name="professional[full_name]"
                id="full_name"
                required
                placeholder="Tu nombre"
                autocomplete="name"
                value={Ecto.Changeset.get_field(@changeset, :full_name)}
                style="width:100%; padding:10px 14px; border:1.5px solid #e2e8f0; border-radius:12px; font-size:14px; color:#1e293b; background:#fff; outline:none;"
              />
              <p
                :for={error <- Keyword.get_values(@changeset.errors, :full_name)}
                style="margin-top:4px; font-size:11px; color:#dc2626;"
              >
                {elem(error, 0)}
              </p>
            </div>

            <%!-- Password field --%>
            <div>
              <label
                for="password"
                style="display:block; font-size:12px; font-weight:600; color:#475569; margin-bottom:6px;"
              >
                Contraseña
              </label>
              <input
                type="password"
                name="professional[password]"
                id="password"
                required
                placeholder="••••••••"
                autocomplete="new-password"
                style="width:100%; padding:10px 14px; border:1.5px solid #e2e8f0; border-radius:12px; font-size:14px; color:#1e293b; background:#fff; outline:none;"
              />
              <p style="margin-top:4px; font-size:11px; color:#94a3b8;">
                La contraseña debe tener al menos 12 caracteres.
              </p>
              <p
                :for={error <- Keyword.get_values(@changeset.errors, :password)}
                style="margin-top:4px; font-size:11px; color:#dc2626;"
              >
                {elem(error, 0)}
              </p>
            </div>

            <%!-- Submit button --%>
            <button
              type="submit"
              style="width:100%; padding:12px; background:linear-gradient(135deg, #6366f1, #818cf8); color:#fff; font-size:14px; font-weight:600; border:none; border-radius:12px; cursor:pointer; box-shadow:0 2px 8px rgba(99,102,241,.3);"
            >
              Crear cuenta
            </button>
          </.form>
        </div>

        <%!-- Login link --%>
        <p style="text-align:center; margin-top:20px; font-size:13px; color:#64748b;">
          ¿Ya tenés cuenta?
          <a href="/login" style="color:#6366f1; font-weight:600; text-decoration:none;">
            Iniciá sesión
          </a>
        </p>

        <%!-- Security note --%>
        <p style="text-align:center; margin-top:12px; font-size:11px; color:#94a3b8;">
          Tus datos están protegidos con cifrado de extremo a extremo
        </p>
      </div>
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
