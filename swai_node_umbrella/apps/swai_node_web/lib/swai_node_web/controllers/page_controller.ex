defmodule SwaiNodeWeb.PageController do
  use SwaiNodeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
