defmodule MallorcaServerWeb.RoomLive do
  @moduledoc """
  A room: a live Orca grid editor plus the roster of connected players. Joining
  monitors this LiveView process, so closing the tab leaves automatically.
  Keystrokes become `edit` messages routed to the host; the host streams back
  evaluated `snapshot`s that we render. See `docs/m6-network-protocol.md`.
  """
  use MallorcaServerWeb, :live_view

  alias MallorcaServer.{Rooms, RoomServer}

  @impl true
  def mount(%{"code" => code} = params, _session, socket) do
    code = String.upcase(code)

    name =
      case params |> Map.get("name", "") |> String.trim() do
        "" -> "anon-#{:rand.uniform(9999)}"
        n -> n
      end

    socket =
      assign(socket,
        code: code,
        name: name,
        pid: nil,
        roster: [],
        host_online: false,
        rows: [],
        gw: 0,
        gh: 0,
        cx: 0,
        cy: 0,
        tick: 0
      )

    if connected?(socket) do
      Phoenix.PubSub.subscribe(MallorcaServer.PubSub, "room:#{code}")
      %{pid: id} = Rooms.join(code, name, self())
      {:ok, assign(socket, pid: id)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_info({:roster, roster, host_online}, socket) do
    {:noreply, assign(socket, roster: roster, host_online: host_online)}
  end

  def handle_info({:snapshot, snap}, socket) do
    gw = snap["w"]
    gh = snap["h"]
    grid = snap["grid"]

    rows =
      if is_binary(grid) and gw > 0 and gh > 0 and byte_size(grid) >= gw * gh do
        for y <- 0..(gh - 1), do: binary_part(grid, y * gw, gw)
      else
        socket.assigns.rows
      end

    {:noreply, assign(socket, rows: rows, gw: gw, gh: gh, tick: snap["tick"])}
  end

  @impl true
  def handle_event("key", params, socket) do
    # Let Cmd/Ctrl chords (paste, copy, …) through without typing a glyph.
    if params["metaKey"] || params["ctrlKey"] do
      {:noreply, socket}
    else
      {:noreply, handle_key(socket, params["key"])}
    end
  end

  def handle_event("paste", %{"text" => text}, socket) do
    {:noreply, apply_paste(socket, text)}
  end

  # No grid yet (host offline) — ignore edits/motion.
  defp handle_key(%{assigns: %{rows: []}} = socket, _key), do: socket

  defp handle_key(socket, key) do
    %{cx: cx, cy: cy, gw: gw, gh: gh} = socket.assigns

    case key do
      "ArrowLeft" ->
        assign(socket, cx: max(cx - 1, 0))

      "ArrowRight" ->
        assign(socket, cx: min(cx + 1, gw - 1))

      "ArrowUp" ->
        assign(socket, cy: max(cy - 1, 0))

      "ArrowDown" ->
        assign(socket, cy: min(cy + 1, gh - 1))

      "Backspace" ->
        socket |> put_edit(".") |> assign(cx: max(cx - 1, 0))

      "Delete" ->
        put_edit(socket, ".")

      _ ->
        if glyph?(key),
          do: socket |> put_edit(key) |> assign(cx: min(cx + 1, gw - 1)),
          else: socket
    end
  end

  # Send the edit to the host and echo it locally (reconciled by the next snapshot).
  defp put_edit(socket, ch) do
    %{code: code, pid: pid, cx: x, cy: y, rows: rows} = socket.assigns

    if pid, do: RoomServer.edit(code, %{t: "edit", pid: pid, x: x, y: y, g: ch})

    rows =
      List.update_at(rows, y, fn row ->
        <<pre::binary-size(^x), _::binary-size(1), rest::binary>> = row
        pre <> ch <> rest
      end)

    assign(socket, rows: rows)
  end

  # A single printable, non-space ASCII glyph (letters, digits, Orca operators).
  defp glyph?(<<c>>) when c in 33..126, do: true
  defp glyph?(_), do: false

  # Paste a multi-line block at the cursor: overlay locally and send the host a
  # single `paste` message (reconciled by the next snapshot).
  defp apply_paste(%{assigns: %{rows: []}} = socket, _text), do: socket

  defp apply_paste(socket, text) do
    %{code: code, pid: pid, cx: x, cy: y, gw: gw, gh: gh, rows: rows} = socket.assigns

    lines =
      text |> String.replace("\r\n", "\n") |> String.trim_trailing("\n") |> String.split("\n")

    if pid do
      RoomServer.edit(code, %{t: "paste", pid: pid, x: x, y: y, cells: Enum.join(lines, "\n")})
    end

    assign(socket, rows: overlay_lines(rows, lines, x, y, gw, gh))
  end

  defp overlay_lines(rows, lines, x0, y0, gw, gh) do
    lines
    |> Enum.with_index()
    |> Enum.reduce(rows, fn {line, i}, acc ->
      y = y0 + i
      if y >= 0 and y < gh, do: List.update_at(acc, y, &put_line(&1, line, x0, gw)), else: acc
    end)
  end

  defp put_line(row, line, x0, gw) do
    line
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reduce(row, fn {ch, j}, r ->
      x = x0 + j

      if x >= 0 and x < gw and byte_size(ch) == 1 do
        <<pre::binary-size(^x), _::binary-size(1), rest::binary>> = r
        pre <> ch <> rest
      else
        r
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="editor" phx-hook="Paste" class="space-y-4 py-6" phx-window-keydown="key">
        <div class="flex items-center justify-between max-w-3xl mx-auto">
          <h1 class="text-xl font-bold text-secondary">
            Room <span class="font-mono text-primary">{@code}</span>
          </h1>
          <span class={[
            "badge font-mono",
            (@host_online && "badge-success") || "badge-outline badge-error"
          ]}>
            host {(@host_online && "online") || "offline"}
          </span>
        </div>

        <div
          :if={@rows != []}
          class="mx-auto w-fit font-mono text-sm leading-none border border-base-300 rounded p-3 bg-base-200 text-primary"
        >
          <div :for={{row, y} <- Enum.with_index(@rows)} class="flex">
            <span
              :for={x <- 0..(@gw - 1)}
              class={[
                "inline-block w-[1ch] text-center",
                (x == @cx and y == @cy) && "bg-primary text-primary-content",
                String.at(row, x) == "." && "opacity-25"
              ]}
            >{String.at(row, x)}</span>
          </div>
        </div>
        <p :if={@rows == []} class="text-center opacity-60">waiting for host…</p>

        <p class="text-center text-xs opacity-60">
          <span class="font-mono text-primary">
            {if rem(@tick || 0, 2) == 0, do: "■", else: "□"}
          </span>
          · type to edit · arrows to move
        </p>

        <div class="max-w-3xl mx-auto">
          <h2 class="text-xs uppercase tracking-wide text-secondary mb-2">
            Players ({length(@roster)})
          </h2>
          <ul class="flex flex-wrap gap-2">
            <li :for={p <- @roster} class="badge badge-outline badge-accent font-mono">
              {p.name}<span :if={p.id == @pid} class="opacity-60">&nbsp;(you)</span>
            </li>
          </ul>
        </div>

        <.link navigate={~p"/"} class="btn btn-ghost btn-sm">← leave</.link>
      </div>
    </Layouts.app>
    """
  end
end
