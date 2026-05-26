defmodule AletheaWeb.Router do
  use AletheaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AletheaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
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

  # Other scopes may use custom stacks.
  # scope "/api", AletheaWeb do
  #   pipe_through :api
  # end
end
