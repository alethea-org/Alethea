defmodule AletheaWeb.Router do
  use AletheaWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {AletheaWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(AletheaWeb.Plugs.ProfessionalAuth, :fetch_current_professional)
  end

  # Auth routes need a different root layout (no sidebar/topbar)
  pipeline :browser_auth do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {AletheaWeb.Layouts, :auth})
    plug(:put_layout, false)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(AletheaWeb.Plugs.ProfessionalAuth, :fetch_current_professional)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :require_auth do
    plug(AletheaWeb.Plugs.ProfessionalAuth, :require_authenticated_professional)
  end

  pipeline :redirect_if_auth do
    plug(AletheaWeb.Plugs.ProfessionalAuth, :redirect_if_authenticated)
  end

  # Health check endpoints (no auth required)
  scope "/health", AletheaWeb do
    get("/", HealthController, :liveness)
    get("/ready", HealthController, :readiness)
  end

  scope "/webhooks", AletheaWeb do
    pipe_through(:api)

    get("/whatsapp", WhatsappWebhookController, :verify)
    post("/whatsapp", WhatsappWebhookController, :receive)
  end

  scope "/", AletheaWeb do
    pipe_through(:browser)

    get("/", PageController, :home)
  end

  scope "/", AletheaWeb do
    pipe_through([:browser_auth, :redirect_if_auth])

    # Controller-based auth (working properly)
    get("/login", SessionController, :new)
    post("/login", SessionController, :create)
    get("/register", RegistrationController, :new)
    post("/register", RegistrationController, :create)
  end

  scope "/", AletheaWeb do
    pipe_through(:browser)

    delete("/logout", SessionController, :delete)
  end

  scope "/", AletheaWeb do
    pipe_through([:browser, :require_auth])

    live_session :require_authenticated_professional,
      on_mount: [
        {AletheaWeb.Plugs.ProfessionalAuth, :mount_current_professional},
        {AletheaWeb.Plugs.ProfessionalAuth, :require_authenticated_professional}
      ] do
      live("/dashboard", DashboardLive, :index)
      live("/dashboard/patients/:id", DashboardLive, :show)
      live("/patients", PatientLive.Index, :index)
      live("/patients/new", PatientLive.Index, :new)
      live("/admin/oban-dashboard", ObanDashboardLive, :index)
    end
  end
end
