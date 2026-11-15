defmodule Toscanini.Workers.WebclipSaveWorker do
  @moduledoc """
  Saves the composed webclip in `commit` mode: the webclipper writes clipping
  + note in its own clone of the Scholion repo, one commit, and pushes.
  An expired operation goes back to compose.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher, Webclip, WebclipFlow}
  alias Toscanini.Clients.Webclipper

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pipeline_id" => pid}, attempt: attempt, max_attempts: max}) do
    pipeline = Repo.get!(Pipeline, pid)
    op_id = get_in(Pipeline.get_results(pipeline), ["webclip_compose", "operation_id"])
    outcome = Webclipper.save(op_id)

    case Webclip.classify_save(outcome, attempt >= max) do
      :ok ->
        saved =
          case outcome do
            {:ok, s} -> s
            _ -> %{}
          end

        Pipeline.save_result(pipeline, "webclip_save", %{
          "slug" => saved["slug"],
          "note_path" => saved["notePath"],
          "clipping_path" => saved["clippingPath"],
          "commit" => saved["commit"]
        })

        Dispatcher.advance(pid)
        :ok

      :recompose ->
        pipeline |> Pipeline.changeset(%{current_step: "webclip_compose"}) |> Repo.update!()
        Dispatcher.rerun(pid)
        :ok

      :retry ->
        {:error, "webclipper save: transient"}

      {:park, reason, detail} ->
        WebclipFlow.park(pipeline, reason, detail)

      {:fail, message} ->
        WebclipFlow.fail(pipeline, message)
    end
  end
end
