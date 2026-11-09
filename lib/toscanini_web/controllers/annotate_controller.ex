defmodule ToscaniniWeb.AnnotateController do
  @moduledoc """
  Re-anota um episódio já publicado, sem re-coletar/re-transcrever/re-resumir.

  Recebe o path relativo do episódio em vox-content ou vox-private-content (com ou
  sem extensão, e com ou sem o prefixo `privado/<token>/` do site privado) e
  inicia o pipeline direto no passo `summarize`, de forma que o próximo passo
  seja `annotate` (Toscanini.Workers.AnnotateWorker), o mesmo worker que já
  roda em produção para os feeds com `auto_annotate: true`. Dali em diante o
  pipeline segue o fluxo normal: enrich_tags → write_files → git_commit →
  s3_archive → notify. Sem gate humano, por design (ver AnnotateWorker).
  """
  use ToscaniniWeb, :controller
  alias Toscanini.{ContentRepos, Repo, Pipeline, Pipeline.Dispatcher}

  def create(conn, %{"path" => path}) do
    slug = slug_of(path)

    case ContentRepos.locate_json(path, slug) do
      {:ok, json_path, private?} ->
        json_data = json_path |> File.read!() |> Jason.decode!()
        title = json_data["title"] || slug
        id = Ecto.UUID.generate()

        initial_results =
          Jason.encode!(%{
            "collect" => %{"json" => json_path, "slug" => slug, "title" => title}
          })

        Repo.insert!(%Pipeline{
          id: id,
          content_type: "podcast_episode",
          collector: "reannotate",
          status: "queued",
          # Episódio achado no repositório privado segue privado: o write_files e o
          # git_commit escrevem de volta no mesmo repositório.
          params: Jason.encode!(Map.merge(%{"auto_annotate" => true}, if(private?, do: %{"private" => true}, else: %{}))),
          results: initial_results,
          current_step: "summarize"
        })

        Dispatcher.advance(id)

        conn |> put_status(202) |> json(%{job_id: id, status: "queued"})

      :error ->
        conn
        |> put_status(404)
        |> json(%{ok: false, error: "episode json not found for path/slug", path: path, slug: slug})
    end
  end

  def create(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required field: path"})
  end

  defp slug_of(path) do
    path
    |> ContentRepos.normalize_path()
    |> String.trim_trailing(".json")
    |> String.trim_trailing(".md")
    |> String.split("/")
    |> List.last()
  end
end
