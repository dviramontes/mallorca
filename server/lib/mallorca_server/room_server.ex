defmodule MallorcaServer.RoomServer do
  @moduledoc """
  Runtime state for one room: the attached host connection (if any) and the set
  of connected browser players. This process is the source of truth for the
  roster. It monitors each player's LiveView process (so a closed tab auto-
  leaves), notifies the host of `player_join`/`player_leave` over the TCP link,
  and broadcasts roster changes to LiveViews over PubSub.

  See `docs/m6-network-protocol.md`.
  """
  use GenServer
  require Logger

  alias MallorcaServer.{Rooms, HostConn}

  def start_link(code) do
    GenServer.start_link(__MODULE__, code, name: Rooms.via(code))
  end

  def attach_host(code, host_pid) do
    GenServer.call(Rooms.via(code), {:attach_host, host_pid})
  end

  def join(code, name, subscriber_pid) do
    GenServer.call(Rooms.via(code), {:join, name, subscriber_pid})
  end

  @impl true
  def init(code) do
    {:ok, %{code: code, host: nil, players: %{}, bpm: 120, playing: false}}
  end

  @impl true
  def handle_call({:attach_host, host_pid}, _from, state) do
    Process.monitor(host_pid)
    Logger.info("room #{state.code}: host attached")
    state = %{state | host: host_pid}
    broadcast_roster(state)
    {:reply, %{players: roster(state), bpm: state.bpm, playing: state.playing}, state}
  end

  @impl true
  def handle_call({:join, name, sub}, _from, state) do
    ref = Process.monitor(sub)
    id = gen_player_id()
    state = put_in(state.players[sub], %{id: id, name: name, ref: ref})
    Logger.info("room #{state.code}: + #{name} (#{id})")
    notify_host(state, %{t: "player_join", pid: id, name: name})
    broadcast_roster(state)
    {:reply, %{pid: id}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    cond do
      pid == state.host ->
        Logger.info("room #{state.code}: host detached")
        state = %{state | host: nil}
        broadcast_roster(state)
        {:noreply, state}

      Map.has_key?(state.players, pid) ->
        {player, players} = Map.pop(state.players, pid)
        state = %{state | players: players}
        Logger.info("room #{state.code}: - #{player.name} (#{player.id})")
        notify_host(state, %{t: "player_leave", pid: player.id})
        broadcast_roster(state)
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  defp roster(state) do
    state.players |> Map.values() |> Enum.map(&%{id: &1.id, name: &1.name})
  end

  defp notify_host(%{host: nil}, _msg), do: :ok
  defp notify_host(%{host: host}, msg), do: HostConn.send_msg(host, msg)

  defp broadcast_roster(state) do
    Phoenix.PubSub.broadcast(
      MallorcaServer.PubSub,
      "room:#{state.code}",
      {:roster, roster(state), state.host != nil}
    )
  end

  defp gen_player_id, do: :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
end
