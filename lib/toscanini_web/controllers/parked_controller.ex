defmodule ToscaniniWeb.ParkedController do
  @moduledoc """
  The queue of parked pipelines — work the server can't finish alone and that
  waits for Claude Code on the author's machine (logged-in Chrome).

    * `GET  /parked`              — list (optional `?content_type=`)
    * `POST /parked/:id/resume`   — resume; webclip accepts `text`, `title`,
      `related_notes` (page captured in the browser / notes to link)
    * `POST /parked/:id/dismiss`  — give up, with a `reason`
  """
  use ToscaniniWeb, :controller
  import Ecto.Query
  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}

  def index(conn, params) do
    query =
      from p in Pipeline,
        where: p.status == "parked",
        order_by: [asc: p.updated_at]

    query =
      case params["content_type"] do
        ct when is_binary(ct) and ct != "" -> where(query, [p], p.content_type == ^ct)
        _ -> query
      end

    items = query |> Repo.all() |> Enum.map(&summary/1)
    json(conn, %{count: length(items), items: items})
  end

  def resume(conn, %{"id" => id} = params) do
    result =
      with {:ok, pipeline} <- fetch_parked(id) do
        results = Pipeline.get_results(pipeline)

        resume =
          %{
            "text" => params["text"],
            "title" => params["title"],
            "related_notes" => params["related_notes"]
          }
          |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)
          |> Map.new()

        results =
          results
          |> Map.put("resume", resume)
          |> Map.put("last_parked", results["parked"])
          |> Map.delete("parked")

        # A webclip always resumes at compose: whatever parked it (browser,
        # red audit, save conflict) needs a fresh operation.
        step =
          if pipeline.content_type == "scholion_webclip",
            do: "webclip_compose",
            else: pipeline.current_step

        pipeline
        |> Pipeline.changeset(%{
          results: Jason.encode!(results),
          current_step: step,
          status: "running"
        })
        |> Repo.update!()

        case Dispatcher.rerun(id) do
          :ok -> conn |> put_status(202) |> json(%{job_id: id, status: "running", step: step})
          {:error, reason} -> conn |> put_status(409) |> json(%{error: reason})
        end
      end

    respond(result, conn)
  end

  def dismiss(conn, %{"id" => id} = params) do
    result =
      with {:ok, pipeline} <- fetch_parked(id) do
        reason = params["reason"] |> to_string() |> String.trim()
        reason = if reason == "", do: "no reason given", else: reason
        # "manual" keeps it out of the failure counters (Toscanini.Status).
        Pipeline.fail(pipeline, "manual dismiss: #{reason}")
        json(conn, %{job_id: id, status: "failed", dismissed: true})
      end

    respond(result, conn)
  end

  defp fetch_parked(id) do
    case Repo.get(Pipeline, id) do
      nil -> {:error, 404, "not found"}
      %Pipeline{status: "parked"} = p -> {:ok, p}
      %Pipeline{status: s} -> {:error, 409, "pipeline is #{s}, not parked"}
    end
  end

  defp respond(%Plug.Conn{} = done, _conn), do: done

  defp respond({:error, status, message}, conn),
    do: conn |> put_status(status) |> json(%{error: message})

  defp summary(p) do
    results = Pipeline.get_results(p)
    input = results["input"] || %{}
    parked = results["parked"] || %{}

    %{
      id: p.id,
      content_type: p.content_type,
      url: input["url"],
      quotes: input["quotes"] || [],
      comment: input["comment"],
      reason: parked["reason"],
      code: parked["code"],
      message: parked["message"],
      findings: parked["findings"] || [],
      step: parked["step"],
      parked_at: parked["at"],
      inserted_at: p.inserted_at
    }
  end
end
