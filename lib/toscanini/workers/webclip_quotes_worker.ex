defmodule Toscanini.Workers.WebclipQuotesWorker do
  @moduledoc """
  Opens one `scholion_quote` pipeline per phrase the author sent with the
  webclip, with the page as source. Each quote pipeline runs (and notifies)
  on its own. No phrases → just advances.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher, Webclip}
  alias Toscanini.Scholion.QuoteJob

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    pipeline = Repo.get!(Pipeline, pid)
    results = Pipeline.get_results(pipeline)

    # Idempotent: a retry after the quotes were opened must not open them again.
    if results["webclip_quotes"] do
      Dispatcher.advance(pid)
    else
      compose = results["webclip_compose"] || %{}
      url = compose["url"] || get_in(results, ["input", "url"])
      title = compose["clip_title"] || compose["title"]

      job_ids =
        results
        |> get_in(["input", "quotes"])
        |> Webclip.normalize_quotes()
        |> Enum.map(fn quote ->
          QuoteJob.create(%{
            "quote" => quote,
            "source_url" => url,
            "context" => "Trecho da página \"#{title}\" (#{url})."
          })
        end)

      Pipeline.save_result(pipeline, "webclip_quotes", %{"job_ids" => job_ids})
      Dispatcher.advance(pid)
    end

    :ok
  end
end
