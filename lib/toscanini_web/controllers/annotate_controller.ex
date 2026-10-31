defmodule ToscaniniWeb.AnnotateController do
  @moduledoc """
  Re-anota um episódio já publicado, sem re-coletar/re-transcrever/re-resumir.

  Recebe o path relativo do episódio em vox-content (com ou sem extensão) e
  inicia o pipeline direto no passo `summarize`, de forma que o próximo passo
  seja `annotate` (Toscanini.Workers.AnnotateWorker), o mesmo worker que já
  roda em produção para os feeds com `auto_annotate: true`. Dali em diante o
  pipeline segue o fluxo normal: enrich_tags → write_files → git_commit →
  s3_archive → notify. Sem gate humano, por design (ver AnnotateWorker).
  """
  use ToscaniniWeb, :controller
  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}

  def create(conn, %{"path" => path}) do
    vox_content_dir = System.fetch_env!("TOSCANINI_VOX_CONTENT_DIR")
    slug = slug_of(path)

    case resolve_json_path(vox_content_dir, path, slug) do
      {:ok, json_path} ->
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
          params: Jason.encode!(%{"auto_annotate" => true}),
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
    |> String.trim_trailing(".json")
    |> String.trim_trailing(".md")
    |> String.split("/")
    |> List.last()
  end

  # Tenta o path exato primeiro (case-sensitive, formato canônico
  # YYYY/MM/Wnn/slug); se não existir, cai pra busca por slug
  # case-insensitive em todo o vox-content, o que cobre URLs públicas
  # (lowercase) e paths digitados com casing diferente.
  defp resolve_json_path(vox_content_dir, path, slug) do
    direct = Path.join(vox_content_dir, Path.rootname(path) <> ".json")

    if File.exists?(direct) do
      {:ok, direct}
    else
      case find_by_slug(vox_content_dir, slug) do
        nil -> :error
        found -> {:ok, found}
      end
    end
  end

  defp find_by_slug(vox_content_dir, slug) do
    target = String.downcase(slug)

    vox_content_dir
    |> Path.join("**/*.json")
    |> Path.wildcard()
    |> Enum.find(fn p -> String.downcase(Path.basename(p, ".json")) == target end)
  end
end

