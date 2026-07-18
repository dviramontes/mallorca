defmodule MallorcaServerWeb.AdminLiveTest do
  use MallorcaServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MallorcaServer.{Rooms, RoomServer}

  defp admin_conn(conn) do
    put_req_header(conn, "authorization", Plug.BasicAuth.encode_basic_auth("admin", "mallorca"))
  end

  test "the dashboard requires basic auth", %{conn: conn} do
    assert get(conn, "/admin").status == 401
  end

  test "shows a room, its players, and each player's latest grid", %{conn: conn} do
    code = Rooms.gen_code()
    player = spawn(fn -> Process.sleep(:infinity) end)
    %{pid: id} = Rooms.join(code, "alice", player)

    RoomServer.route_snapshot(code, %{
      "pid" => id,
      "w" => 3,
      "h" => 1,
      "grid" => "D..",
      "tick" => 1
    })

    # a synchronous call flushes the route_snapshot cast so the cache is set
    RoomServer.info(code)

    {:ok, lv, html} = live(admin_conn(conn), ~p"/admin")
    assert html =~ code
    assert render(lv) =~ "alice"
    assert render(lv) =~ "D.."

    Process.exit(player, :kill)
  end

  test "shows the native host as a participant with its own grid", %{conn: conn} do
    code = Rooms.gen_code()
    Rooms.attach_host(code, spawn(fn -> Process.sleep(:infinity) end))

    RoomServer.route_snapshot(code, %{
      "pid" => "host",
      "w" => 3,
      "h" => 1,
      "grid" => "C..",
      "tick" => 0
    })

    RoomServer.info(code)

    {:ok, lv, _html} = live(admin_conn(conn), ~p"/admin")
    assert render(lv) =~ "host (native)"
    assert render(lv) =~ "C.."
  end
end
