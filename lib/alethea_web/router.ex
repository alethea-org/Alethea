defmodule AletheaWeb.Router do
  use AletheaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AletheaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug AletheaWeb.Plugs.ProfessionalAuth, :fetch_current_professional
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_auth do
    plug AletheaWeb.Plugs.ProfessionalAuth, :require_authenticated_professional
  end

  pipeline :redirect_if_auth do
    plug AletheaWeb.Plugs.ProfessionalAuth, :redirect_if_authenticated
  end

  scope "/webhooks", AletheaWeb do
    pipe_through :api

    get "/whatsapp", WhatsappWebhookController, :verify
    post "/whatsapp", WhatsappWebhookController, :receive
  end

  scope "/", AletheaWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", AletheaWeb do
    pipe_through [:browser, :redirect_if_auth]

    live_session :redirect_if_authenticated,
      on_mount: [{AletheaWeb.Plugs.ProfessionalAuth, :mount_current_professional}] do
      live "/register", ProfessionalRegistrationLive, :new
      live "/login", LoginLive, :new
    end

    post "/login", SessionController, :create
  end

  scope "/", AletheaWeb do
    pipe_through :browser

    delete "/logout", SessionController, :delete
  end

  scope "/", AletheaWeb do
    pipe_through [:browser, :require_auth]

    live_session :require_authenticated_professional,
      on_mount: [
        {AletheaWeb.Plugs.ProfessionalAuth, :mount_current_professional},
        {AletheaWeb.Plugs.ProfessionalAuth, :require_authenticated_professional}
      ] do
      live "/dashboard", DashboardLive, :index
      live "/dashboard/patients/:id", DashboardLive, :show
      live "/patients", PatientLive.Index, :index
      live "/patients/new", PatientLive.Index, :new
    end
  end
end
