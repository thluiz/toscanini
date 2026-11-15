defmodule ToscaniniWeb.WebclipPublishController do
  @moduledoc """
  `POST /api/orchestrator/publish/webclip` — the single entry point any agent
  (Claudinho or whatever replaces it) calls to clip a page into the Scholion.

      {"url": "https://...", "quotes": ["frase 1", "frase 2"], "comment": "..."}

  The caller decides nothing: retries, parking for the browser, quotes and
  notifications are all pipeline steps (see `Toscanini.Webclip`).
  """
  use ToscaniniWeb, :controller
  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher, Webclip}

  def create(conn, %{"url" => url} = params) when is_binary(url) do
    url = String.trim(url)

    if http_url?(url) do
      case existing(url) do
        {id, status} ->
          conn |> put_status(200) |> json(%{job_id: id, status: status, duplicate: true})

        nil ->
          id = start(url, params)
          conn |> put_status(202) |> json(%{job_id: id, status: "queued"})
      end
    else
      conn |> put_status(400) |> json(%{error: "url must be http(s)"})
    end
  end

  def create(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required field: url"})
  end

  defp start(url, params) do
    id = Ecto.UUID.generate()

    input = %{
      "url"     => url,
      "quotes"  => Webclip.normalize_quotes(params["quotes"]),
      "comment" => params["comment"]
    }

    Repo.insert!(%Pipeline{
      id:           id,
      content_type: "scholion_webclip",
      collector:    "publish_webclip",
      status:       "queued",
      params:       Jason.encode!(%{"url" => url}),
      results:      Jason.encode!(%{"input" => input}),
      # advance/1 runs the successor: the first worker is WebclipComposeWorker.
      current_step: "webclip_queued"
    })

    Dispatcher.advance(id)
    id
  end

  # Same URL already clipped, in flight or parked → hand back that job instead
  # of composing (and paying for) it again. Failed ones may be retried.
  defp existing(url) do
    sql = """
    SELECT id, status FROM pipelines
    WHERE content_type = 'scholion_webclip'
      AND status IN ('queued', 'running', 'parked', 'done')
      AND json_extract(params, '$.url') = ?
    ORDER BY inserted_at DESC
    LIMIT 1
    """

    case Repo.query(sql, [url]) do
      {:ok, %{rows: [[id, status]]}} -> {id, status}
      _ -> nil
    end
  end

  defp http_url?(url) do
    case URI.parse(url) do
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) and h != "" -> true
      _ -> false
    end
  end
end
