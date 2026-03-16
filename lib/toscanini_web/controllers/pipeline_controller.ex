defmodule ToscaniniWeb.PipelineController do
  use ToscaniniWeb, :controller

  def prioritize(conn, %{"id" => pipeline_id}) do
    sql = "UPDATE oban_jobs SET priority = -1 WHERE state = 'available' AND json_extract(args, '$.pipeline_id') = ?"
    {:ok, %{num_rows: count}} = Toscanini.Repo.query(sql, [pipeline_id])
    json(conn, %{ok: true, pipeline_id: pipeline_id, updated: count})
  end

  def find_by_url(conn, %{"url" => url}) do
    sql = "SELECT id, status, current_step, inserted_at FROM pipelines WHERE json_valid(params) AND json_extract(params, '$.url') = ? ORDER BY inserted_at DESC LIMIT 1"
    case Toscanini.Repo.query(sql, [url]) do
      {:ok, %{rows: [[id, status, step, inserted_at]]}} ->
        json(conn, %{ok: true, pipeline_id: id, status: status, current_step: step, inserted_at: inserted_at})
      {:ok, %{rows: []}} ->
        conn |> put_status(404) |> json(%{ok: false, error: "pipeline not found for url"})
      {:error, reason} ->
        conn |> put_status(500) |> json(%{ok: false, error: inspect(reason)})
    end
  end
end
