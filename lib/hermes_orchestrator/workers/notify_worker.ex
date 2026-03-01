defmodule HermesOrchestrator.Workers.NotifyWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias HermesOrchestrator.{Repo, Pipeline}
  alias HermesOrchestrator.Clients.GossipGate

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    pipeline  = Repo.get!(Pipeline, pid)
    collect   = Pipeline.get_results(pipeline)["collect"]
    json_path = collect["json"]
    json_data = json_path |> File.read!() |> Jason.decode!()

    title   = get_in(json_data, ["frontmatter", "title"]) || collect["title"] || "Episódio"
    podcast = get_in(json_data, ["metadata", "podcast"]) || ""

    msg = "<b>✅ Podcast processado</b>\n\n<b>#{title}</b>\n#{podcast}\n\n<code>#{json_path}</code>"
    GossipGate.send(msg)

    pipeline
    |> Pipeline.changeset(%{status: "done", current_step: "done"})
    |> Repo.update!()

    :ok
  end
end
