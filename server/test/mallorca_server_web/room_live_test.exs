defmodule MallorcaServerWeb.RoomLiveTest do
  use MallorcaServerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias MallorcaServer.Rooms

  test "a player sees themselves in the room", %{conn: conn} do
    code = Rooms.gen_code()
    {:ok, lv, html} = live(conn, ~p"/room/#{code}?name=alice")
    assert html =~ "Room"
    assert render(lv) =~ "alice"
    assert render(lv) =~ "you"
  end

  test "two players in the same room see each other", %{conn: conn} do
    code = Rooms.gen_code()
    {:ok, lv1, _} = live(conn, ~p"/room/#{code}?name=alice")
    {:ok, lv2, _} = live(build_conn(), ~p"/room/#{code}?name=bob")

    assert eventually(fn -> render(lv1) =~ "bob" end)
    assert eventually(fn -> render(lv2) =~ "alice" end)
  end

  test "room shows host offline until a host attaches", %{conn: conn} do
    code = Rooms.gen_code()
    {:ok, lv, _} = live(conn, ~p"/room/#{code}?name=alice")
    assert render(lv) =~ "host offline"

    Rooms.attach_host(code, spawn(fn -> Process.sleep(:infinity) end))
    assert eventually(fn -> render(lv) =~ "host online" end)
  end

  # Roster updates arrive via PubSub (async); retry briefly before asserting.
  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries <= 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end
end
