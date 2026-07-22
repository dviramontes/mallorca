defmodule MallorcaServerWeb.AdminLive do
  @moduledoc """
  Admin dashboard: every active room, its players, host online/offline, and a
  read-only view of each player's latest evaluated grid. Auto-refreshes.
  """
  use MallorcaServerWeb, :live_view

  alias MallorcaServer.Rooms

  @refresh_ms 1000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)
    {:ok, assign(socket, rooms: Rooms.list_rooms())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, rooms: Rooms.list_rooms())}
  end

  defp grid_rows(%{"grid" => grid, "w" => w, "h" => h})
       when is_binary(grid) and w > 0 and h > 0 and byte_size(grid) >= w * h do
    for y <- 0..(h - 1), do: binary_part(grid, y * w, w)
  end

  defp grid_rows(_), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6 py-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold text-secondary">Admin · rooms ({length(@rooms)})</h1>
          <span class="text-xs opacity-60 font-mono">auto-refresh 1s</span>
        </div>

        <p :if={@rooms == []} class="opacity-60">no active rooms.</p>

        <div :for={room <- @rooms} class="border border-base-300 rounded p-4 space-y-3 bg-base-200">
          <div class="flex items-center gap-3">
            <h2 class="text-lg font-bold font-mono text-primary">{room.code}</h2>
            <span class={[
              "badge font-mono",
              (room.host_online && "badge-success") || "badge-outline badge-error"
            ]}>
              host {(room.host_online && "online") || "offline"}
            </span>
            <span class="badge badge-outline badge-accent font-mono">
              {length(room.players)} player(s)
            </span>
          </div>

          <div class="flex flex-wrap gap-4">
            <div :for={p <- room.players} class="space-y-1">
              <div class="text-xs font-mono">
                <span class="text-secondary">{p.name}</span>
                <span class="opacity-40">{p.id}</span>
              </div>
              <% rows = grid_rows(room.snapshots[p.id]) %>
              <div
                :if={rows != []}
                class="font-mono text-[10px] leading-none border border-base-300 rounded p-2 bg-base-100 text-primary"
              >
                <div :for={row <- rows} class="whitespace-pre">{row}</div>
              </div>
              <div :if={rows == []} class="text-xs opacity-40">no grid yet</div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
