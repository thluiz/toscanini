defmodule Toscanini.Workers.ScholionCommitWorker do
  @moduledoc """
  Commita + push da nota no repo de conteúdo Scholion, via o helper
  `Toscanini.Git` (auth resolvida pelo remote do clone / ~/.ssh/config).
  """
  use Oban.Worker, queue: :git_commit, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    scholion_dir = System.fetch_env!("TOSCANINI_SCHOLION_DIR")

    pipeline = Repo.get!(Pipeline, pid)
    results = Pipeline.get_results(pipeline)
    dest = results["scholion_write"]["dest"]
    title = get_in(results, ["scholion_synthesize", "title"]) || "nota"
    draft = get_in(results, ["scholion_synthesize", "draft"]) == true
    msg = if draft, do: "note(draft): #{title}", else: "note: #{title}"

    case Toscanini.Git.commit_and_push(scholion_dir, [dest], msg) do
      {:ok, output} ->
        Pipeline.save_result(pipeline, "scholion_commit", %{"done" => true, "output" => output})
        Dispatcher.advance(pid)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
