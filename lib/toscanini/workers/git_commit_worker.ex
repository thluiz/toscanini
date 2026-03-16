defmodule Toscanini.Workers.GitCommitWorker do
  use Oban.Worker, queue: :git_commit, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    vox_content_dir = System.fetch_env!("TOSCANINI_VOX_CONTENT_DIR")

    pipeline    = Repo.get!(Pipeline, pid)
    write_files = Pipeline.get_results(pipeline)["write_files"]
    dest_json   = write_files["dest_json"]
    dest_md     = write_files["dest_md"]
    title       = write_files["title"] || "Episode"

    # Stage and commit the files written by write_files step first,
    # so that git pull --rebase has a clean working tree
    {_out, 0} = System.cmd("git", ["add", dest_json, dest_md], cd: vox_content_dir)

    {commit_output, commit_status} =
      System.cmd("git", ["commit", "-m", "Add: #{title}"],
        cd: vox_content_dir,
        stderr_to_stdout: true
      )

    nothing_to_commit = String.contains?(commit_output, "nothing to commit")

    if commit_status != 0 and not nothing_to_commit do
      {:error, "git commit failed (#{commit_status}): #{commit_output}"}
    else
      # Sync with remote after committing to avoid conflicts on push
      {pull_out, pull_status} =
        System.cmd("git", ["pull", "--rebase"],
          cd: vox_content_dir,
          stderr_to_stdout: true
        )

      if pull_status != 0 do
        {:error, "git pull --rebase failed (#{pull_status}): #{pull_out}"}
      else
        {push_out, push_status} =
          System.cmd("git", ["push"], cd: vox_content_dir, stderr_to_stdout: true)

        if push_status != 0 do
          {:error, "git push failed (#{push_status}): #{push_out}"}
        else
          Pipeline.save_result(pipeline, "git_commit", %{"done" => true, "output" => String.trim(commit_output)})
          Dispatcher.advance(pid)
          :ok
        end
      end
    end
  end
end
