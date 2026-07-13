defmodule Toscanini.Workers.ScholionWriteWorker do
  @moduledoc """
  Escreve a nota composta em `content/notes/<slug>.md` dentro do clone do repo
  de conteúdo Scholion (`TOSCANINI_SCHOLION_DIR`). O preset já entrega markdown
  pronto — sem renderer, diferente do WriteFilesWorker (que renderiza JSON→MD).
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    scholion_dir = System.fetch_env!("TOSCANINI_SCHOLION_DIR")

    pipeline = Repo.get!(Pipeline, pid)
    synth = Pipeline.get_results(pipeline)["scholion_synthesize"]
    slug = synth["slug"]
    note = synth["note"]

    dest = Path.join([scholion_dir, "content", "notes", slug <> ".md"])
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, note)

    Pipeline.save_result(pipeline, "scholion_write", %{"dest" => dest, "slug" => slug})
    Dispatcher.advance(pid)
    :ok
  end
end
