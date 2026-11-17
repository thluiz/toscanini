defmodule Toscanini.Workers.WebclipComposeWorker do
  @moduledoc """
  Calls the webclipper `compose` (fetch + extract + summary + ghost-audit).

  URL mode by default; text mode when the pipeline was resumed with page text
  captured in the author's browser (`results.resume`). Transient errors retry
  through Oban; what the server alone can't solve parks the pipeline
  (see `Toscanini.Webclip.classify_compose/2`).
  """
  use Oban.Worker, queue: :webclip, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher, Webclip, WebclipFlow}
  alias Toscanini.Clients.Webclipper

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pipeline_id" => pid}, attempt: attempt, max_attempts: max}) do
    pipeline = Repo.get!(Pipeline, pid)
    results = Pipeline.get_results(pipeline)
    body =
      Webclip.compose_body(results["input"], results["resume"])
      |> Webclip.with_draft_slug(results["webclip_draft"])

    outcome = Webclipper.compose(body)

    case Webclip.classify_compose(outcome, attempt >= max, body["url"]) do
      :ok ->
        {:ok, op} = outcome
        save(pipeline, pid, op)

      :retry ->
        {:error, "webclipper compose: transient (#{inspect(summary(outcome))})"}

      {:park, "audit_red", detail} ->
        {:ok, op} = outcome
        {pipeline, detail} = save_draft(pipeline, op, detail)
        WebclipFlow.park(pipeline, "audit_red", detail)

      {:park, reason, detail} ->
        WebclipFlow.park(pipeline, reason, detail)

      {:fail, message} ->
        WebclipFlow.fail(pipeline, message)
    end
  end

  # A red note goes into the vault as an unpublished draft before the
  # pipeline parks, so the capture and the composed text never depend on the
  # webclipper's 24h operation. Resuming recomposes with the draft's slug
  # (see `Webclip.with_draft_slug/2`) and the next save replaces the draft.
  # If the draft save itself fails, the pipeline still parks, saying so.
  defp save_draft(pipeline, op, detail) do
    case Webclipper.save(op["operationId"], draft: true) do
      {:ok, saved} ->
        draft = %{
          "slug" => saved["slug"],
          "note_path" => saved["notePath"],
          "clipping_path" => saved["clippingPath"],
          "operation_id" => op["operationId"],
          "commit" => saved["commit"]
        }

        pipeline = Pipeline.save_result(pipeline, "webclip_draft", draft)
        {pipeline, Map.put(detail, "draft_note", saved["notePath"])}

      other ->
        {pipeline, Map.put(detail, "draft_error", inspect(other) |> String.slice(0, 300))}
    end
  end

  defp save(pipeline, pid, op) do
    audit = op["audit"] || %{}
    note = op["note"] || %{}
    clipping = op["clipping"] || %{}

    Pipeline.save_result(pipeline, "webclip_compose", %{
      "operation_id" => op["operationId"],
      "expires_at" => op["expiresAt"],
      "slug" => note["slug"],
      "title" => note["title"] || clipping["title"],
      "language" => note["language"],
      "url" => clipping["url"],
      "clip_title" => clipping["title"],
      "verdict" => audit["verdict"],
      "findings" => audit["findings"] || [],
      "audit_summary" => audit["summary"],
      "mode" =>
        if(get_in(Pipeline.get_results(pipeline), ["resume", "text"]), do: "text", else: "url")
    })

    Dispatcher.advance(pid)
    :ok
  end

  defp summary({:api_error, e}), do: e["code"]
  defp summary({:error, reason}), do: reason
  defp summary({:ok, op}),
    do: "clipping #{get_in(op, ["clipping", "url"])}; audit #{get_in(op, ["audit", "summary"])}"
end
