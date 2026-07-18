defmodule MallorcaServer.RoomServerTest do
  use ExUnit.Case, async: false

  alias MallorcaServer.Rooms

  setup do
    code = Rooms.gen_code()
    Phoenix.PubSub.subscribe(MallorcaServer.PubSub, "room:#{code}")
    %{code: code}
  end

  test "join adds a player and broadcasts the roster", %{code: code} do
    player = spawn_player()
    %{pid: id} = Rooms.join(code, "alice", player)

    assert_receive {:roster, roster, _host_online}
    assert Enum.any?(roster, &(&1.name == "alice" and &1.id == id))
  end

  test "a player's process dying removes it from the roster", %{code: code} do
    player = spawn_player()
    Rooms.join(code, "bob", player)
    assert_receive {:roster, [_one], _}

    Process.exit(player, :kill)
    assert_receive {:roster, [], _}
  end

  test "roster reports host presence", %{code: code} do
    # no host yet
    Rooms.join(code, "carol", spawn_player())
    assert_receive {:roster, _roster, false}

    # attach a fake host process
    host = spawn_player()
    Rooms.attach_host(code, host)
    assert_receive {:roster, _roster, true}

    # host dies -> back to offline
    Process.exit(host, :kill)
    assert_receive {:roster, _roster, false}
  end

  defp spawn_player, do: spawn(fn -> Process.sleep(:infinity) end)
end
