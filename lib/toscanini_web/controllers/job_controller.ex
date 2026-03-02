defmodule ToscaniniWeb.JobController do
  use ToscaniniWeb, :controller
  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}

  def create(conn, params) do
    id = Ecto.UUID.generate()
    Repo.insert!(%Pipeline{
      id:           id,
      content_type: params["content_type"],
      collector:    params["collector"],
      status:       "queued",
      params:       Jason.encode!(params["params"] || %{})
    })
    Dispatcher.advance(id)
    conn |> put_status(202) |> json(%{job_id: id, status: "queued"})
  end

  def show(conn, %{"id" => id}) do
    p = Repo.get!(Pipeline, id)
    json(conn, %{
      id:           p.id,
      status:       p.status,
      current_step: p.current_step,
      results:      Pipeline.get_results(p),
      error:        p.error
    })
  end
end
