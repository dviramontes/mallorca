defmodule MallorcaServerWeb.HomeLive do
  @moduledoc "Landing page: create a new room or join one by code."
  use MallorcaServerWeb, :live_view

  alias MallorcaServer.Rooms

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, name: "", code: "")}
  end

  @impl true
  def handle_event("update", %{"name" => name} = params, socket) do
    {:noreply, assign(socket, name: name, code: Map.get(params, "code", ""))}
  end

  @impl true
  def handle_event("create", _params, socket) do
    code = Rooms.gen_code()
    {:noreply, push_navigate(socket, to: ~p"/room/#{code}?#{[name: socket.assigns.name]}")}
  end

  @impl true
  def handle_event("join", _params, socket) do
    case socket.assigns.code |> String.trim() |> String.upcase() do
      "" ->
        {:noreply, put_flash(socket, :error, "Enter a room code to join.")}

      code ->
        {:noreply, push_navigate(socket, to: ~p"/room/#{code}?#{[name: socket.assigns.name]}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-md space-y-6 py-8">
        <div class="space-y-1">
          <h1 class="text-2xl font-bold text-primary">mallorca</h1>
          <p class="text-sm text-secondary uppercase tracking-wide">network mode</p>
        </div>
        <p class="opacity-70">
          A networked
          <a
            href="https://100r.co/site/orca.html"
            target="_blank"
            rel="noopener"
            class="text-accent hover:text-secondary"
          >orca</a>
          livecoding environment. Create a room and share the code, or join an existing one.
        </p>

        <form phx-change="update" class="space-y-3">
          <input
            name="name"
            value={@name}
            placeholder="your name"
            class="input input-bordered w-full bg-base-200"
          />
          <input
            name="code"
            value={@code}
            placeholder="room code (to join)"
            class="input input-bordered w-full font-mono uppercase tracking-widest bg-base-200"
          />
        </form>

        <div class="flex gap-3">
          <button phx-click="create" class="btn btn-primary">Create room</button>
          <button phx-click="join" class="btn btn-outline btn-accent">Join room</button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
