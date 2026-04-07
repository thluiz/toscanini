defmodule ToscaniniWeb.IngestLocalController do
  use ToscaniniWeb, :controller
  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}

  def create(conn, %{"slug" => slug, "json" => json_data, "duration_secs" => duration_secs} = params) do
    collected_dir = Application.get_env(:toscanini, :collected_dir)
    mp3_path = Path.join(collected_dir, "#{slug}.mp3")

    if not File.exists?(mp3_path) do
      conn |> put_status(422) |> json(%{error: "mp3 not found: #{mp3_path}"})
    else
      id = Ecto.UUID.generate()
      json_path = Path.join(collected_dir, "#{slug}.json")
      File.write!(json_path, Jason.encode!(json_data, pretty: true))

      title = json_data["metadata"]["title"] || json_data["title"] || slug
      podcast = json_data["metadata"]["podcast"] || ""
      source_url = params["source_url"] || ""

      initial_results = Jason.encode!(%{
        "collect" => %{
          "mp3"           => mp3_path,
          "json"          => json_path,
          "slug"          => slug,
          "title"         => title,
          "podcast"       => podcast,
          "duration_secs" => duration_secs,
          "source_url"    => source_url
        }
      })

      Repo.insert!(%Pipeline{
        id:           id,
        content_type: "podcast",
        collector:    "local_ingest",
        status:       "queued",
        params:       Jason.encode!(%{"url" => source_url, "slug" => slug}),
        results:      initial_results,
        current_step: "collect"
      })

      Dispatcher.advance(id)

      conn |> put_status(202) |> json(%{job_id: id, status: "queued"})
    end
  end

  def create(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required fields: slug, json, duration_secs"})
  end
end
