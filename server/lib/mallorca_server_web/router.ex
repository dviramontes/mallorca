defmodule MallorcaServerWeb.Router do
  use MallorcaServerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MallorcaServerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :admin_auth do
    plug :admin_basic_auth
  end

  defp admin_basic_auth(conn, _opts) do
    cfg = Application.get_env(:mallorca_server, :admin_auth, [])

    Plug.BasicAuth.basic_auth(conn,
      username: cfg[:username] || "admin",
      password: cfg[:password] || "mallorca"
    )
  end

  scope "/", MallorcaServerWeb do
    pipe_through :browser

    # Single-room demo: both the landing page and the native client's legacy
    # room URL open the same fixed room; RoomLive ignores the path code.
    live "/", RoomLive
    live "/room/:code", RoomLive
  end

  scope "/admin", MallorcaServerWeb do
    pipe_through [:browser, :admin_auth]

    live "/", AdminLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", MallorcaServerWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:mallorca_server, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MallorcaServerWeb.Telemetry
    end
  end
end
