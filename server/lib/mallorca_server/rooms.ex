defmodule MallorcaServer.Rooms do
  @moduledoc """
  Lookup + lifecycle for `RoomServer` processes — one per room code, registered
  in `MallorcaServer.RoomRegistry` and supervised by
  `MallorcaServer.RoomSupervisor`. See `docs/m6-network-protocol.md`.
  """
  alias MallorcaServer.RoomServer

  @registry MallorcaServer.RoomRegistry
  @supervisor MallorcaServer.RoomSupervisor

  # The single, fixed demo room. Network mode is a one-room show: the native
  # host attaches here (no code negotiation) and every browser lands here.
  @demo_code "MYROOM"

  @doc "The fixed demo room code every host and browser shares."
  def demo_code, do: @demo_code

  @doc "Registry `:via` tuple for a room's GenServer."
  def via(code), do: {:via, Registry, {@registry, code}}

  @doc "Return the room's pid, starting it if it doesn't exist yet."
  def ensure(code) do
    case Registry.lookup(@registry, code) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {RoomServer, code}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  @doc """
  Join `subscriber_pid` (a LiveView) to the room. The server assigns the player
  an Orca-operator name (no user-chosen names). Returns %{pid: id, name: name}.
  """
  def join(code, subscriber_pid) do
    ensure(code)
    RoomServer.join(code, subscriber_pid)
  end

  @doc "Attach the host connection to the room. Returns %{players, bpm, playing}."
  def attach_host(code, host_pid) do
    ensure(code)
    RoomServer.attach_host(code, host_pid)
  end

  @doc "Info for every active room (for the admin dashboard)."
  def list_rooms do
    @registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.map(&RoomServer.info/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.code)
  end

  @doc "Generate a 6-char room code from an unambiguous base32 alphabet."
  def gen_code do
    alphabet = ~c"23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    for _ <- 1..6, into: "", do: <<Enum.random(alphabet)>>
  end
end
