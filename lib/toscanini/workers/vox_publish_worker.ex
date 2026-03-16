defmodule Toscanini.Workers.VoxPublishWorker do
  use Oban.Worker, queue: :vox_publish, max_attempts: 2

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    vox_publish_bin = System.fetch_env!("TOSCANINI_VOX_PUBLISH_BIN")

    pipeline = Repo.get!(Pipeline, pid)

    {output, status} =
      System.cmd(vox_publish_bin, ["--skip-pull"], stderr_to_stdout: true)

    if status != 0 do
      {:error, "vox-publish failed (#{status}): #{String.slice(output, 0, 500)}"}
    else
      Pipeline.save_result(pipeline, "vox_publish", %{"done" => true})
      Dispatcher.advance(pid)
      :ok
    end
  end
end
