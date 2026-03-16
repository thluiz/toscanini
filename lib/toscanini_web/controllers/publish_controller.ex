defmodule ToscaniniWeb.PublishController do
  use ToscaniniWeb, :controller
  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}

  def create(conn, %{"path" => path, "json" => json_data}) do
    id = Ecto.UUID.generate()

    temp_path = "/tmp/publish_#{id}.json"
    File.write!(temp_path, Jason.encode!(json_data, pretty: true))

    slug = path
           |> String.trim_trailing(".md")
           |> String.trim_trailing(".json")
           |> String.split("/")
           |> List.last()

    title = json_data["title"] || slug

    initial_results = Jason.encode!(%{
      "collect" => %{
        "json"  => temp_path,
        "slug"  => slug,
        "title" => title
      }
    })

    Repo.insert!(%Pipeline{
      id:           id,
      content_type: "podcast_episode",
      collector:    "publish_json",
      status:       "queued",
      params:       "{}",
      results:      initial_results,
      current_step: "enrich_tags"
    })

    Dispatcher.advance(id)

    conn |> put_status(202) |> json(%{job_id: id, status: "queued"})
  end

  def create(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required fields: path, json"})
  end
end
