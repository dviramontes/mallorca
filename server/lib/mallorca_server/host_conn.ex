defmodule MallorcaServer.HostConn do
  @moduledoc """
  One native-host TCP connection, as a GenServer that owns the socket in active
  mode so it can both *receive* the host's messages and *be sent to* (e.g. when
  a player joins). Newline-delimited JSON wire protocol; see
  `docs/m6-network-protocol.md`.

  M6 scope: `hello` -> `welcome`, `ping` -> `pong`, and outbound
  `player_join`/`player_leave` (pushed by `RoomServer`). Later milestones add
  edits, snapshots, and transport.
  """
  use GenServer, restart: :temporary
  require Logger

  alias MallorcaServer.{Rooms, RoomServer}

  @proto_version 1

  def start_link(socket), do: GenServer.start_link(__MODULE__, socket)

  @doc "Called by the listener once it has transferred socket ownership to us."
  def activate(pid), do: GenServer.cast(pid, :activate)

  @doc "Push a protocol message (a map) to the host."
  def send_msg(pid, map), do: GenServer.cast(pid, {:send, map})

  @impl true
  def init(socket), do: {:ok, %{socket: socket, room: nil}}

  @impl true
  def handle_cast(:activate, state) do
    :inet.setopts(state.socket, active: :once)
    {:noreply, state}
  end

  def handle_cast({:send, map}, state) do
    send_line(state.socket, map)
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, socket, line}, state) do
    state = handle_line(state, line)
    :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    Logger.info("HostConn: host disconnected (room #{inspect(state.room)})")
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.warning("HostConn: tcp error #{inspect(reason)}")
    {:stop, :normal, state}
  end

  defp handle_line(state, line) do
    case Jason.decode(String.trim_trailing(line)) do
      {:ok, %{"t" => "hello"} = msg} ->
        on_hello(state, msg)

      {:ok, %{"t" => "ping"} = msg} ->
        send_line(state.socket, %{t: "pong", ts: Map.get(msg, "ts")})
        state

      {:ok, %{"t" => "snapshot"} = msg} ->
        RoomServer.route_snapshot(state.room, msg)
        state

      {:ok, %{"t" => t}} ->
        Logger.info("HostConn: <- (unhandled) #{t}")
        state

      {:error, err} ->
        Logger.warning("HostConn: bad JSON #{inspect(err)}")
        state
    end
  end

  defp on_hello(state, msg) do
    room = Map.get(msg, "room") || Rooms.gen_code()
    %{players: players, bpm: bpm, playing: playing} = Rooms.attach_host(room, self())

    send_line(state.socket, %{
      t: "welcome",
      v: @proto_version,
      room: room,
      bpm: bpm,
      playing: playing,
      players: Enum.map(players, &%{pid: &1.id, name: &1.name})
    })

    Logger.info("HostConn: host for room #{room} (#{length(players)} player(s))")
    %{state | room: room}
  end

  defp send_line(socket, map), do: :gen_tcp.send(socket, [Jason.encode!(map), ?\n])
end
