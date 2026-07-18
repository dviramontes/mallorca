defmodule MallorcaServer.HostListener do
  @moduledoc """
  Accepts native-host TCP connections and hands each socket to a `HostConn`
  GenServer (supervised by `MallorcaServer.HostConnSupervisor`). The listener
  itself does nothing but accept; all protocol handling lives in `HostConn`.

  See `docs/m6-network-protocol.md`.
  """
  use GenServer
  require Logger

  alias MallorcaServer.HostConn

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 4001)
    listen_opts = [:binary, packet: :line, active: false, reuseaddr: true]

    case :gen_tcp.listen(port, listen_opts) do
      {:ok, listen} ->
        Logger.info("HostListener: listening for the host on TCP #{port}")
        # Kick off the (blocking) accept loop without blocking init/1.
        send(self(), :accept)
        {:ok, %{listen: listen, port: port}}

      {:error, reason} ->
        # Don't take the whole app down (e.g. port already bound) — log and
        # stay out of the supervision tree.
        Logger.error("HostListener: could not listen on #{port}: #{inspect(reason)}")
        :ignore
    end
  end

  @impl true
  def handle_info(:accept, %{listen: listen} = state) do
    {:ok, socket} = :gen_tcp.accept(listen)

    {:ok, pid} =
      DynamicSupervisor.start_child(MallorcaServer.HostConnSupervisor, {HostConn, socket})

    # Transfer ownership, *then* let the conn arm active mode (avoids a race
    # where tcp messages would be delivered to the listener).
    :ok = :gen_tcp.controlling_process(socket, pid)
    HostConn.activate(pid)

    send(self(), :accept)
    {:noreply, state}
  end
end
