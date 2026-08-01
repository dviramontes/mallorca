defmodule MallorcaServerWeb.EditorLoopTest do
  @moduledoc "Full round trip: LiveView edit -> host (TCP) -> snapshot -> LiveView render."
  use MallorcaServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @port Application.compile_env(:mallorca_server, :host_port, 4001)

  test "an edit reaches the host and its snapshot renders back", %{conn: conn} do
    # A fake host attaches to the room first.
    {:ok, host} =
      :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, packet: :line, active: false], 1000)

    send_line(host, %{t: "hello"})
    assert %{"t" => "welcome"} = recv_msg(host)

    # A browser joins and opens the editor; the host is told about the player.
    {:ok, lv, _html} = live(conn, ~p"/")
    assert %{"t" => "player_join", "pid" => pid} = recv_msg(host)

    # Host streams an initial (blank) grid; the LiveView renders it.
    send_line(host, %{t: "snapshot", pid: pid, w: 3, h: 1, grid: "...", tick: 0})
    assert eventually(fn -> has_element?(lv, "#session-#{pid}") end)
    lv |> element("#session-#{pid}") |> render_click()
    assert eventually(fn -> has_element?(lv, "#grid") end)

    # Typing a glyph sends an edit at the cursor (0,0) to the host...
    render_hook(lv, "key", %{"key" => "D"})
    assert %{"t" => "edit", "pid" => ^pid, "x" => 0, "y" => 0, "g" => "D"} = recv_msg(host)

    # ...and the host's evaluated snapshot shows up in the editor.
    send_line(host, %{t: "snapshot", pid: pid, w: 3, h: 1, grid: "D..", tick: 1})
    assert eventually(fn -> render(lv) =~ "D" end)

    :gen_tcp.close(host)
  end

  test "a multi-line paste is forwarded to the host as one paste message", %{conn: conn} do
    {:ok, host} =
      :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, packet: :line, active: false], 1000)

    send_line(host, %{t: "hello"})
    assert %{"t" => "welcome"} = recv_msg(host)

    {:ok, lv, _html} = live(conn, ~p"/")
    assert %{"t" => "player_join", "pid" => pid} = recv_msg(host)

    send_line(host, %{
      t: "snapshot",
      pid: pid,
      w: 10,
      h: 4,
      grid: String.duplicate(".", 40),
      tick: 0
    })

    assert eventually(fn -> has_element?(lv, "#session-#{pid}") end)
    lv |> element("#session-#{pid}") |> render_click()
    assert eventually(fn -> has_element?(lv, "#grid") end)

    render_hook(lv, "paste", %{"text" => "..C\n..7"})

    assert %{"t" => "paste", "pid" => ^pid, "x" => 0, "y" => 0, "cells" => "..C\n..7"} =
             recv_msg(host)

    :gen_tcp.close(host)
  end

  defp send_line(sock, map), do: :ok = :gen_tcp.send(sock, [Jason.encode!(map), ?\n])

  defp recv_msg(sock) do
    {:ok, line} = :gen_tcp.recv(sock, 0, 1000)
    Jason.decode!(line)
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries <= 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end
end
