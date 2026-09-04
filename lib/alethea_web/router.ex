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

  # Landing page (`GET /`) — same HTML doc shell as :browser, but
  # no `#auth-layout` wrapper. The editorial home needs full-bleed
  # hero, two-column CTA, and the three-step band to use the full
  # viewport; the auth-layout's centred flex box would box them in.
  pipeline :landing do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {AletheaWeb.Layouts, :landing})
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

  # Telegram webhook + auth routes.
  #
  # The POST `/webhooks/telegram/` route is behind the
  # `TelegramSecretToken` plug (validates the
  # `X-Telegram-Bot-Api-Secret-Token` header against
  # `BotConfig.secret_token/0`). The GET `/webhooks/telegram/auth`
  # route is a public patient-facing URL with a 10-minute TTL token —
  # the secret-token check does NOT apply (design §8 rationale: the
  # auth route carries its own TTL'd token in the query string, the
  # plug is the auth surface for the POST).
  pipeline :telegram_webhook do
    plug(:accepts, ["json"])
    plug(AletheaWeb.Plugs.TelegramSecretToken)
  end

  scope "/webhooks/telegram", AletheaWeb do
    pipe_through(:telegram_webhook)

    post("/", TelegramWebhookController, :update)
  end

  scope "/webhooks/telegram", AletheaWeb do
    pipe_through(:api)

    get("/auth", TelegramAuthController, :consume)
  end

  scope "/", AletheaWeb do
    pipe_through([:landing])

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

      live(
        "/patients/:patient_id/target_behaviors/:id/review",
        TargetBehaviorLive.Review,
        :show
      )

      live(
        "/patients/:patient_id/clinical-search",
        PatientLive.ClinicalSearch,
        :index
      )

      live("/prototype/clinical-review", ClinicalReviewPrototypeLive, :index)
      live("/prototype/eorc-shape", EorcShapeComparisonPrototypeLive, :index)
      live("/admin/oban-dashboard", ObanDashboardLive, :index)
    end
  end
end
