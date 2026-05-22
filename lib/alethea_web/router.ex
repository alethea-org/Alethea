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

  pipeline :require_auth do
    plug AletheaWeb.Plugs.ProfessionalAuth, :require_authenticated_professional
  end

  pipeline :redirect_if_auth do
    plug AletheaWeb.Plugs.ProfessionalAuth, :redirect_if_authenticated
  end

  scope "/", AletheaWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", AletheaWeb do
    pipe_through [:browser, :redirect_if_auth]

    live "/login", LoginLive, :new
    post "/login", SessionController, :create
  end

  scope "/", AletheaWeb do
    pipe_through :browser

    delete "/logout", SessionController, :delete
  end

  scope "/", AletheaWeb do
    pipe_through [:browser, :require_auth]

    live "/dashboard", DashboardLive, :index
  end
end
