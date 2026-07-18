defmodule MallorcaServer.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MallorcaServerWeb.Telemetry,
      MallorcaServer.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:mallorca_server, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:mallorca_server, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MallorcaServer.PubSub},
      # Room lookup (code -> RoomServer) and the room process supervisor.
      {Registry, keys: :unique, name: MallorcaServer.RoomRegistry},
      {DynamicSupervisor, name: MallorcaServer.RoomSupervisor, strategy: :one_for_one},
      # Per-connection host handlers + the TCP/NDJSON listener for the native
      # host (docs/m6-network-protocol.md).
      {DynamicSupervisor, name: MallorcaServer.HostConnSupervisor, strategy: :one_for_one},
      {MallorcaServer.HostListener,
       port: Application.get_env(:mallorca_server, :host_port, 4001)},
      # Start to serve requests, typically the last entry
      MallorcaServerWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MallorcaServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MallorcaServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
