defmodule DifyWeb.PageController do
  use DifyWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
