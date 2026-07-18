defmodule MallorcaServerWeb.PageController do
  use MallorcaServerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
