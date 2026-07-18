defmodule MallorcaServerWeb.RoomLive do
  @moduledoc """
  A room: shows the live roster of connected players and whether the native host
  is online. Joining monitors this LiveView process, so closing the tab leaves
  the room automatically. See `docs/m6-network-protocol.md`.
  """
  use MallorcaServerWeb, :live_view

  alias MallorcaServer.Rooms

  @impl true
  def mount(%{"code" => code} = params, _session, socket) do
    code = String.upcase(code)

    name =
      case params |> Map.get("name", "") |> String.trim() do
        "" -> "anon-#{:rand.uniform(9999)}"
        n -> n
      end

    socket = assign(socket, code: code, name: name, pid: nil, roster: [], host_online: false)

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-md space-y-6 py-8">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">
            Room <span class="font-mono">{@code}</span>
          </h1>
          <span class={["badge", (@host_online && "badge-success") || "badge-ghost"]}>
            host {(@host_online && "online") || "offline"}
          </span>
        </div>

        <div>
          <h2 class="text-sm uppercase tracking-wide opacity-60 mb-2">
            Players ({length(@roster)})
          </h2>
          <ul class="space-y-1">
            <li :for={p <- @roster} class="flex items-center gap-2">
              <span class="font-mono text-xs opacity-50">{p.id}</span>
              <span>{p.name}</span>
              <span :if={p.id == @pid} class="badge badge-sm badge-primary">you</span>
            </li>
          </ul>
          <p :if={@roster == []} class="opacity-60">no players yet…</p>
        </div>

        <.link navigate={~p"/"} class="btn btn-ghost btn-sm">← leave</.link>
      </div>
    </Layouts.app>
    """
  end
end
