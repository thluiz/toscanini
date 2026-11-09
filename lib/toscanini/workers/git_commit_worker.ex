defmodule Toscanini.Workers.GitCommitWorker do
  use Oban.Worker, queue: :git_commit, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    pipeline    = Repo.get!(Pipeline, pid)
    vox_content_dir = Pipeline.content_dir(pipeline)
    write_files = Pipeline.get_results(pipeline)["write_files"]
    dest_json   = write_files["dest_json"]
    dest_md     = write_files["dest_md"]
    title       = write_files["title"] || "Episode"

    # Stage, commit, pull --rebase and push via the shared repo-parameterized
    # helper (auth resolved by the clone's remote / ~/.ssh/config).
    case Toscanini.Git.commit_and_push(vox_content_dir, [dest_json, dest_md], "Add: #{title}") do
      {:ok, commit_output} ->
        Pipeline.save_result(pipeline, "git_commit", %{"done" => true, "output" => commit_output})
        Dispatcher.advance(pid)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
