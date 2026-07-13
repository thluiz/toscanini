defmodule ToscaniniWeb.StatusController do
  use ToscaniniWeb, :controller

  def index(conn, _params) do
    json(conn, Toscanini.Status.snapshot())
  end
end
