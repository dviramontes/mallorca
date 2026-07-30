defmodule MallorcaServerWeb.RoomLive do
  @moduledoc """
  The single demo room: one browser view for every connected session. Browsers
  receive an operator name automatically and can select any active session to
  watch it. A browser may only edit its own session; the native host and other
  browser sessions are read-only.
  """
  use MallorcaServerWeb, :live_view

  alias MallorcaServer.{Rooms, RoomServer}

  @impl true
  def mount(_params, _session, socket) do
    code = Rooms.demo_code()

    socket =
      socket
      |> assign(
        code: code,
        name: nil,
        pid: nil,
        roster: [],
        host_online: false,
        session_count: 0,
        snapshots: %{},
        selected_pid: nil,
        rows: [],
        gw: 0,
        gh: 0,
        cx: 0,
        cy: 0,
        tick: 0
      )
      |> stream(:sessions, [], dom_id: &"session-#{&1.id}")

    if connected?(socket) do
      Phoenix.PubSub.subscribe(MallorcaServer.PubSub, "room:#{code}")
      %{pid: id, name: name} = Rooms.join(code, self())

      {:ok,
       assign(socket,
         pid: id,
         name: name,
         snapshots: RoomServer.snapshots(code)
       )}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_info({:roster, roster, host_online}, socket) do
    selected_pid =
      if session_active?(socket.assigns.selected_pid, roster, host_online),
        do: socket.assigns.selected_pid,
        else: nil

    {:noreply,
     socket
     |> assign(roster: roster, host_online: host_online, selected_pid: selected_pid)
     |> stream_sessions()
     |> show_snapshot(selected_pid)}
  end

  def handle_info({:snapshot, snap}, socket) do
    snapshots = Map.put(socket.assigns.snapshots, snap["pid"], snap)
    socket = assign(socket, snapshots: snapshots)

    {:noreply,
     if(snap["pid"] == socket.assigns.selected_pid,
       do: show_snapshot(socket, snap["pid"]),
       else: socket
     )}
  end

  @impl true
  def handle_event("select_session", %{"pid" => pid}, socket) do
    if session_active?(pid, socket.assigns.roster, socket.assigns.host_online) do
      {:noreply,
       socket
       |> assign(selected_pid: pid, cx: 0, cy: 0)
       |> stream_sessions()
       |> show_snapshot(pid)}
    else
      {:noreply, socket}
    end
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

  # Only the browser's own session is editable. Selecting the native host or
  # another browser turns this view into a spectator.
  defp handle_key(%{assigns: %{selected_pid: selected, pid: own}} = socket, _key)
       when selected != own,
       do: socket

  # No grid yet — ignore edits/motion.
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

  defp apply_paste(%{assigns: %{selected_pid: selected, pid: own}} = socket, _text)
       when selected != own,
       do: socket

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

  defp session_active?(nil, _roster, _host_online), do: false
  defp session_active?("host", _roster, host_online), do: host_online
  defp session_active?(pid, roster, _host_online), do: Enum.any?(roster, &(&1.id == pid))

  defp show_snapshot(socket, nil) do
    assign(socket, rows: [], gw: 0, gh: 0, tick: 0)
  end

  defp show_snapshot(socket, pid) do
    case socket.assigns.snapshots[pid] do
      %{"grid" => grid, "w" => gw, "h" => gh} = snap
      when is_binary(grid) and is_integer(gw) and is_integer(gh) and gw > 0 and gh > 0 and
             byte_size(grid) >= gw * gh ->
        rows = for y <- 0..(gh - 1), do: binary_part(grid, y * gw, gw)
        assign(socket, rows: rows, gw: gw, gh: gh, tick: snap["tick"])

      _ ->
        assign(socket, rows: [], gw: 0, gh: 0, tick: 0)
    end
  end

  defp sessions(assigns) do
    host = if assigns.host_online, do: [%{id: "host", name: "native"}], else: []
    host ++ assigns.roster
  end

  defp stream_sessions(socket) do
    sessions = sessions(socket.assigns)

    socket
    |> assign(session_count: length(sessions))
    |> stream(:sessions, sessions, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="session-viewer" phx-hook="Paste" class="space-y-5 py-6" phx-window-keydown="key">
        <div class="flex items-center justify-between max-w-3xl mx-auto">
          <div>
            <p class="text-xs uppercase tracking-[0.2em] text-secondary">live room</p>
            <h1 class="text-xl font-bold font-mono text-primary">{@code}</h1>
          </div>
          <span class={[
            "badge font-mono",
            (@host_online && "badge-success") || "badge-outline badge-error"
          ]}>
            host {(@host_online && "online") || "offline"}
          </span>
        </div>

        <section id="active-sessions" class="max-w-3xl mx-auto space-y-2">
          <div class="flex items-end justify-between gap-3">
            <h2 class="text-xs uppercase tracking-wide text-secondary">
              Active sessions ({@session_count})
            </h2>
            <p :if={@name} id="assigned-name" class="text-xs opacity-60">
              you are <span class="font-mono text-primary">{@name}</span>
            </p>
          </div>
          <div id="active-session-list" phx-update="stream" class="flex flex-wrap gap-2">
            <p id="no-sessions" class="hidden only:block text-sm opacity-60">
              waiting for the native client…
            </p>
            <button
              :for={{dom_id, session} <- @streams.sessions}
              id={dom_id}
              type="button"
              phx-click="select_session"
              phx-value-pid={session.id}
              class={[
                "btn btn-sm font-mono transition-colors",
                session.id == @selected_pid && "btn-primary",
                session.id != @selected_pid && "btn-outline btn-accent"
              ]}
            >
              <span :if={session.id == "host"} aria-hidden="true">◆</span>
              {session.name}
              <span :if={session.id == @pid} class="opacity-60">(you)</span>
            </button>
          </div>
        </section>

        <div
          :if={@rows != []}
          id="grid"
          phx-hook="OpReadout"
          class="mx-auto w-fit font-mono text-sm leading-none border border-base-300 rounded p-3 bg-base-200 text-primary"
        >
          <div :for={{row, y} <- Enum.with_index(@rows)} class="flex">
            <span
              :for={x <- 0..(@gw - 1)}
              data-glyph={String.at(row, x)}
              data-edit-cursor={if(@selected_pid == @pid and x == @cx and y == @cy, do: "true")}
              class={[
                "inline-block w-[1ch] text-center",
                @selected_pid == @pid && x == @cx && y == @cy &&
                  "bg-secondary text-secondary-content",
                String.at(row, x) == "." && "opacity-25"
              ]}
            >{String.at(row, x)}</span>
          </div>
        </div>
        <%!-- M10: operator-name readout, lower-right, italic. Filled by the
              OpReadout JS hook on hover; empty off an operator. --%>
        <div
          id="op-readout"
          phx-update="ignore"
          class="fixed bottom-3 right-4 font-mono text-sm italic text-primary opacity-70 pointer-events-none select-none"
        >
        </div>
        <p :if={@selected_pid == nil} id="select-prompt" class="text-center opacity-60">
          select an active session to watch
        </p>
        <p
          :if={@selected_pid != nil and @rows == []}
          id="grid-waiting"
          class="text-center opacity-60"
        >
          waiting for this session’s first grid…
        </p>

        <p :if={@selected_pid != nil and @rows != []} class="text-center text-xs opacity-60">
          <span class="font-mono text-primary">
            {if rem(@tick || 0, 2) == 0, do: "■", else: "□"}
          </span>
          <%= if @selected_pid == @pid do %>
            · your session · type to edit · arrows to move
          <% else %>
            · watching read-only
          <% end %>
        </p>
      </div>
    </Layouts.app>
    """
  end
end
