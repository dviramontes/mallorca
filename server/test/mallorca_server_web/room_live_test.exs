defmodule MallorcaServerWeb.RoomLiveTest do
  use MallorcaServerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias MallorcaServer.Rooms

  test "the landing page joins the fixed room with an assigned operator name", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/?name=alice")

    assert has_element?(lv, "#session-viewer")
    assert has_element?(lv, "#assigned-name")
    refute render(lv) =~ "alice"
    assert render(lv) =~ Rooms.demo_code()
  end

  test "connected clients appear as selectable sessions", %{conn: conn} do
    {:ok, lv1, _} = live(conn, ~p"/")
    {:ok, lv2, _} = live(build_conn(), ~p"/")

    assert eventually(fn -> has_element?(lv1, "#active-sessions button + button") end)
    assert eventually(fn -> has_element?(lv2, "#active-sessions button + button") end)
  end

  test "room shows host offline until a host attaches", %{conn: conn} do
    code = Rooms.demo_code()
    {:ok, lv, _} = live(conn, ~p"/")
    assert render(lv) =~ "host offline"

    Rooms.attach_host(code, self())
    assert eventually(fn -> render(lv) =~ "host online" end)
    assert eventually(fn -> has_element?(lv, "#session-host", "native") end)
  end

  test "selecting the native session renders its latest grid read-only", %{conn: conn} do
    code = Rooms.demo_code()
    Rooms.attach_host(code, self())

    {:ok, lv, _} = live(conn, ~p"/")

    MallorcaServer.RoomServer.route_snapshot(code, %{
      "t" => "snapshot",
      "pid" => "host",
      "w" => 3,
      "h" => 1,
      "grid" => "C4.",
      "tick" => 2
    })

    assert eventually(fn -> has_element?(lv, "#session-host") end)
    lv |> element("#session-host") |> render_click()

    assert has_element?(lv, "#grid")
    assert render(lv) =~ "watching read-only"
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
