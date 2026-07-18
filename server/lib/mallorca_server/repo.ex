defmodule MallorcaServer.Repo do
  use Ecto.Repo,
    otp_app: :mallorca_server,
    adapter: Ecto.Adapters.SQLite3
end
