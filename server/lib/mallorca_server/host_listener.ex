defmodule MallorcaServer.HostListener do
  @moduledoc """
  Accepts the native host's TCP connection and speaks the newline-delimited
  JSON wire protocol (see `docs/m6-network-protocol.md`).

  M6 spike scope: `hello` -> `welcome` and `ping` -> `pong`. Later milestones
  extend `handle_msg/2` with player lifecycle, edits, snapshots, and transport.
  """
  use GenServer
  require Logger

  @proto_version 1

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

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
        # Don't take the whole app down (e.g. port already bound by another
        # instance) — just log and stay out of the supervision tree.
        Logger.error("HostListener: could not listen on #{port}: #{inspect(reason)}")
        :ignore
    end
  end

  @impl true
  def handle_info(:accept, %{listen: listen} = state) do
    {:ok, socket} = :gen_tcp.accept(listen)

    {:ok, pid} =
      Task.Supervisor.start_child(MallorcaServer.HostConnSupervisor, fn ->
        serve(socket)
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    send(self(), :accept)
    {:noreply, state}
  end

  # --- per-connection handler (runs in a supervised Task) ---

  defp serve(socket) do
    Logger.info("HostListener: host connected")
    loop(socket)
  end

  defp loop(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, line} ->
        handle_line(socket, line)
        loop(socket)

      {:error, :closed} ->
        Logger.info("HostListener: host disconnected")

      {:error, reason} ->
        Logger.warning("HostListener: recv error #{inspect(reason)}")
    end
  end

  defp handle_line(socket, line) do
    case Jason.decode(String.trim_trailing(line)) do
      {:ok, %{"t" => _} = msg} -> handle_msg(socket, msg)
      {:ok, other} -> Logger.warning("HostListener: message without type: #{inspect(other)}")
      {:error, err} -> Logger.warning("HostListener: bad JSON #{inspect(err)} in #{inspect(line)}")
    end
  end

  # hello -> welcome
  defp handle_msg(socket, %{"t" => "hello"} = msg) do
    Logger.info("HostListener: <- hello #{inspect(msg)}")
    room = Map.get(msg, "room") || gen_room_code()

    reply(socket, %{
      t: "welcome",
      v: @proto_version,
      room: room,
      bpm: 120,
      playing: false,
      players: []
    })
  end

  # ping -> pong (echo ts for RTT)
  defp handle_msg(socket, %{"t" => "ping"} = msg) do
    reply(socket, %{t: "pong", ts: Map.get(msg, "ts")})
  end

  defp handle_msg(_socket, %{"t" => t} = msg) do
    Logger.info("HostListener: <- (unhandled) #{t} #{inspect(msg)}")
  end

  defp reply(socket, map) do
    :gen_tcp.send(socket, [Jason.encode!(map), ?\n])
  end

  # 6-char room code, unambiguous base32 (no 0/O/1/I).
  defp gen_room_code do
    alphabet = ~c"23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    for _ <- 1..6, into: "", do: <<Enum.random(alphabet)>>
  end
end
