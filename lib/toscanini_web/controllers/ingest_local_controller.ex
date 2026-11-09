defmodule ToscaniniWeb.IngestLocalController do
  use ToscaniniWeb, :controller
  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}

  def create(conn, %{"slug" => slug, "json" => json_data, "duration_secs" => duration_secs} = params) do
    collected_dir = Application.get_env(:toscanini, :collected_dir)
    mp3_path = Path.join(collected_dir, "#{slug}.mp3")

    # `private: true` marca o conteúdo como privado (repositório privado, MP3 retido
    # para sempre). O sidecar também leva a marca, porque a retenção olha só o sidecar.
    private? = params["private"] in [true, "true"]
    json_data = if private?, do: put_private(json_data), else: json_data

    cond do
      not File.exists?(mp3_path) ->
        conn |> put_status(422) |> json(%{error: "mp3 not found: #{mp3_path}"})

      duplicate_id = Pipeline.find_duplicate_by_slug(slug, "") ->
        # Os arquivos chegam aos poucos: reenviar um já processado não faz nada.
        conn |> put_status(200) |> json(%{job_id: duplicate_id, status: "done", duplicate: true})

      true ->
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
          params:       Jason.encode!(pipeline_params(source_url, slug, private?)),
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

  defp pipeline_params(source_url, slug, true),
    do: %{"url" => source_url, "slug" => slug, "private" => true}

  defp pipeline_params(source_url, slug, false), do: %{"url" => source_url, "slug" => slug}

  defp put_private(json_data) do
    Map.update(json_data, "metadata", %{"private" => true}, &Map.put(&1, "private", true))
  end
end
