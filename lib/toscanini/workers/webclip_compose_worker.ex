defmodule Toscanini.Workers.WebclipComposeWorker do
  @moduledoc """
  Calls the webclipper `compose` (fetch + extract + summary + ghost-audit).

  URL mode by default; text mode when the pipeline was resumed with page text
  captured in the author's browser (`results.resume`). Transient errors retry
  through Oban; what the server alone can't solve parks the pipeline
  (see `Toscanini.Webclip.classify_compose/2`).
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher, Webclip, WebclipFlow}
  alias Toscanini.Clients.Webclipper

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pipeline_id" => pid}, attempt: attempt, max_attempts: max}) do
    pipeline = Repo.get!(Pipeline, pid)
    results = Pipeline.get_results(pipeline)
    body = Webclip.compose_body(results["input"], results["resume"])
    outcome = Webclipper.compose(body)

    case Webclip.classify_compose(outcome, attempt >= max) do
      :ok ->
        {:ok, op} = outcome
        save(pipeline, pid, op)

      :retry ->
        {:error, "webclipper compose: transient (#{inspect(summary(outcome))})"}

      {:park, reason, detail} ->
        WebclipFlow.park(pipeline, reason, detail)

      {:fail, message} ->
        WebclipFlow.fail(pipeline, message)
    end
  end

  defp save(pipeline, pid, op) do
    audit = op["audit"] || %{}
    note = op["note"] || %{}
    clipping = op["clipping"] || %{}

    Pipeline.save_result(pipeline, "webclip_compose", %{
      "operation_id" => op["operationId"],
      "expires_at"   => op["expiresAt"],
      "slug"         => note["slug"],
      "title"        => note["title"] || clipping["title"],
      "language"     => note["language"],
      "url"          => clipping["url"],
      "clip_title"   => clipping["title"],
      "verdict"      => audit["verdict"],
      "findings"     => audit["findings"] || [],
      "audit_summary" => audit["summary"],
      "mode"         => if(get_in(Pipeline.get_results(pipeline), ["resume", "text"]), do: "text", else: "url")
    })

    Dispatcher.advance(pid)
    :ok
  end

  defp summary({:api_error, e}), do: e["code"]
  defp summary({:error, reason}), do: reason
  defp summary({:ok, op}), do: get_in(op, ["audit", "summary"])
end
