defmodule MallorcaServer.HostConnTest do
  @moduledoc "Exercises the real TCP path: a fake host connects and is notified of players."
  use ExUnit.Case, async: false

  alias MallorcaServer.Rooms

  @port Application.compile_env(:mallorca_server, :host_port, 4001)

  test "host gets welcome, then player_join and player_leave over the socket" do
    code = Rooms.gen_code()

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, packet: :line, active: false], 1000)

    send_line(sock, %{t: "hello", v: 1, role: "host", room: code})
    assert %{"t" => "welcome", "room" => ^code, "players" => []} = recv_msg(sock)

    # a browser player joins -> host should receive player_join
    player = spawn(fn -> Process.sleep(:infinity) end)
    %{pid: id, name: name} = Rooms.join(code, player)
    assert %{"t" => "player_join", "pid" => ^id, "name" => ^name} = recv_msg(sock)

    # player leaves -> host should receive player_leave
    Process.exit(player, :kill)
    assert %{"t" => "player_leave", "pid" => ^id} = recv_msg(sock)

    :gen_tcp.close(sock)
  end

  test "ping is answered with pong echoing ts" do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, packet: :line, active: false], 1000)

    send_line(sock, %{t: "hello", room: Rooms.gen_code()})
    assert %{"t" => "welcome"} = recv_msg(sock)

    send_line(sock, %{t: "ping", ts: 42})
    assert %{"t" => "pong", "ts" => 42} = recv_msg(sock)

    :gen_tcp.close(sock)
  end

  test "welcome lists players already in the room, keyed by pid" do
    code = Rooms.gen_code()

    # a player joins before any host attaches
    player = spawn(fn -> Process.sleep(:infinity) end)
    %{pid: id, name: name} = Rooms.join(code, player)

    # the host connects to that specific room
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, packet: :line, active: false], 1000)

    send_line(sock, %{t: "hello", room: code})
    welcome = recv_msg(sock)
    assert %{"t" => "welcome", "room" => ^code} = welcome
    assert [%{"pid" => ^id, "name" => ^name}] = welcome["players"]

    :gen_tcp.close(sock)
    Process.exit(player, :kill)
  end

  test "a host without a room joins the fixed demo room" do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, packet: :line, active: false], 1000)

    send_line(sock, %{t: "hello", v: 1, role: "host"})

    assert %{"t" => "welcome", "room" => room} = recv_msg(sock)
    assert room == Rooms.demo_code()

    :gen_tcp.close(sock)
  end

  defp send_line(sock, map), do: :ok = :gen_tcp.send(sock, [Jason.encode!(map), ?\n])

  defp recv_msg(sock) do
    {:ok, line} = :gen_tcp.recv(sock, 0, 1000)
    Jason.decode!(line)
  end
end
