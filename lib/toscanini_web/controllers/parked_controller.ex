defmodule ToscaniniWeb.ParkedController do
  @moduledoc """
  The queue of parked pipelines — work the server can't finish alone and that
  waits for Claude Code on the author's machine (logged-in Chrome).

    * `GET  /parked`              — list (optional `?content_type=`)
    * `POST /parked/:id/resume`   — resume; webclip accepts `text`, `title`,
      `related_notes` (page captured in the browser / notes to link). Also
      takes a webclip that failed at save: it retries the save.
    * `POST /parked/:id/dismiss`  — give up, with a `reason`
  """
  use ToscaniniWeb, :controller
  import Ecto.Query
  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher, Webclip}

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
      with {:ok, pipeline} <- fetch_resumable(id) do
        results = Pipeline.get_results(pipeline)

        resume =
          %{
            "text" => params["text"],
            "title" => params["title"],
            "related_notes" => params["related_notes"]
          }
          |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)
          |> Map.new()

        # A webclip resumes at compose (whatever parked it needs a fresh
        # operation), except a save that failed transiently: that retries the
        # save of the same operation (Webclip.resume_step/4).
        step =
          if pipeline.content_type == "scholion_webclip",
            do: Webclip.resume_step(pipeline.status, pipeline.current_step, results, resume),
            else: pipeline.current_step

        results =
          results
          |> Map.put("resume", resume)
          |> Map.put("last_parked", results["parked"])
          |> Map.delete("parked")

        pipeline
        |> Pipeline.changeset(%{
          results: Jason.encode!(results),
          current_step: step,
          status: "running",
          error: nil
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

  # Besides parked pipelines, a webclip that failed at save (before 0.2.53 a
  # save that ran out of attempts failed instead of parking) can be resumed:
  # it retries the save of its operation.
  defp fetch_resumable(id) do
    case Repo.get(Pipeline, id) do
      %Pipeline{status: "failed", content_type: "scholion_webclip", current_step: "webclip_save"} = p ->
        {:ok, p}

      _ ->
        fetch_parked(id)
    end
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
