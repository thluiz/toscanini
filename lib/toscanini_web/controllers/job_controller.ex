defmodule ToscaniniWeb.JobController do
  use ToscaniniWeb, :controller
  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}
  import Ecto.Query

  # Schema-level fields — excluded from flat pipeline params
  @schema_keys ~w[content_type collector]

  def create(conn, params) do
    pipeline_params =
      case params["params"] do
        nested when is_map(nested) -> nested
        _ -> Map.drop(params, @schema_keys)
      end

    url = Map.get(pipeline_params, "url", "")

    # Deduplication: return existing done pipeline for same URL
    existing =
      if url != "" do
        Repo.one(
          from p in Pipeline,
            where: like(p.params, ^"%#{url}%") and p.status == "done",
            limit: 1,
            select: p.id
        )
      end

    if existing do
      conn |> put_status(200) |> json(%{job_id: existing, status: "done", duplicate: true})
    else
      id = Ecto.UUID.generate()

      Repo.insert!(%Pipeline{
        id:           id,
        content_type: params["content_type"] || "podcast",
        collector:    params["collector"] || "pocketcasts",
        status:       "queued",
        params:       Jason.encode!(pipeline_params)
      })

      Dispatcher.advance(id)
      conn |> put_status(202) |> json(%{job_id: id, status: "queued"})
    end
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
