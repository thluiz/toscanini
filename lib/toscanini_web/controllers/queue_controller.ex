defmodule ToscaniniWeb.QueueController do
  use ToscaniniWeb, :controller

  def scale(conn, %{"name" => name, "limit" => limit}) do
    queue = String.to_existing_atom(name)
    Oban.scale_queue(queue: queue, limit: limit)
    json(conn, %{ok: true, queue: name, limit: limit})
  end
end
