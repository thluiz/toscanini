defmodule Toscanini.Status do
  @moduledoc """
  Read model para o andamento dos pipelines. Agrega estado dos pipelines,
  a fila de transcrição (oban_jobs) e o progresso ao vivo do whisper num
  único snapshot, consumido pelo endpoint de status e pelo relatório horário.
  """
  import Ecto.Query
  alias Toscanini.{Repo, Pipeline}

  def snapshot do
    %{
      totals:          totals(),
      steps:           running_steps(),
      done_last_hour:  done_last_hour(),
      recent_failures: recent_failures(),
      transcribe:      transcribe_status(),
      next_transcribe: next_transcribe(),
      executing:       executing_jobs()
    }
  end

  defp totals do
    base =
      Repo.all(from p in Pipeline, group_by: p.status, select: {p.status, count(p.id)})
      |> Map.new()

    # "failed" ignora duplicados/cancelamentos manuais, igual ao relatório atual
    failed =
      Repo.one(
        from p in Pipeline,
          where:
            p.status == "failed" and
              not like(p.error, "%duplicate%") and not like(p.error, "%manual%"),
          select: count(p.id)
      )

    %{
      done:    Map.get(base, "done", 0),
      running: Map.get(base, "running", 0),
      queued:  Map.get(base, "queued", 0),
      failed:  failed
    }
  end

  defp running_steps do
    Repo.all(
      from p in Pipeline,
        where: p.status == "running",
        group_by: p.current_step,
        order_by: [desc: count(p.id)],
        select: {p.current_step, count(p.id)}
    )
    |> Map.new()
  end

  # Stateless: substitui a comparação com o state-file .json do script atual
  defp done_last_hour do
    Repo.one(
      from p in Pipeline,
        where:
          p.status == "done" and
            fragment("datetime(?) >= datetime('now', '-1 hour')", p.updated_at),
        select: count(p.id)
    )
  end

  defp recent_failures(limit \\ 5) do
    Repo.all(
      from p in Pipeline,
        where:
          p.status == "failed" and
            fragment("datetime(?) >= datetime('now', '-1 hour')", p.inserted_at) and
            not like(p.error, "%duplicate%") and not like(p.error, "%manual%"),
        order_by: [desc: p.inserted_at],
        limit: ^limit,
        select: %{step: p.current_step, error: p.error}
    )
    |> Enum.map(&%{&1 | error: String.slice(&1.error || "", 0, 80)})
  end

  # oban_jobs não tem schema no app -> SQL cru, como PipelineController.prioritize
  defp transcribe_status do
    sql = """
    SELECT state, COUNT(*) FROM oban_jobs
    WHERE worker LIKE '%TranscribeWorker' AND state IN ('executing','available')
    GROUP BY state
    """

    {:ok, %{rows: rows}} = Repo.query(sql)
    counts = Map.new(rows, fn [state, n] -> {state, n} end)
    %{active: Map.get(counts, "executing", 0), queued: Map.get(counts, "available", 0)}
  end

  defp next_transcribe(limit \\ 5) do
    sql = """
    SELECT p.results FROM pipelines p
    JOIN oban_jobs j ON json_extract(j.args, '$.pipeline_id') = p.id
      AND j.worker LIKE '%TranscribeWorker' AND j.state = 'available'
    WHERE p.status = 'running' AND p.current_step = 'transcribe'
    ORDER BY j.priority ASC, j.scheduled_at ASC
    LIMIT ?
    """

    {:ok, %{rows: rows}} = Repo.query(sql, [limit])
    Enum.map(rows, fn [results] -> title_from_results(results) end)
  end

  defp executing_jobs do
    sql = """
    SELECT json_extract(j.args, '$.pipeline_id'), p.results
    FROM oban_jobs j
    JOIN pipelines p ON p.id = json_extract(j.args, '$.pipeline_id')
    WHERE j.worker LIKE '%TranscribeWorker' AND j.state = 'executing'
    ORDER BY j.attempted_at
    """

    {:ok, %{rows: rows}} = Repo.query(sql)

    Enum.map(rows, fn [pid, results] ->
      prog = read_progress(pid)

      %{
        title:  title_from_results(results),
        device: if(String.contains?(prog.model, "cuda"), do: "GPU", else: "CPU"),
        pct:    prog.progress,
        eta:    prog.eta
      }
    end)
  end

  defp read_progress(pid) do
    default = %{model: "?", progress: "?", eta: "?"}

    case File.read("/tmp/whisper-#{pid}/progress.txt") do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reduce(default, fn line, acc ->
          case String.split(line, ":", parts: 2) do
            ["model", v]    -> %{acc | model: String.trim(v)}
            ["progress", v] -> %{acc | progress: String.trim(v)}
            ["eta", v]      -> %{acc | eta: String.trim(v)}
            _ -> acc
          end
        end)

      _ ->
        default
    end
  end

  defp title_from_results(results) do
    case Jason.decode(results || "{}") do
      {:ok, %{"collect" => %{"title" => t}}} -> t
      _ -> "?"
    end
  end
end
