defmodule Toscanini.Workers.PublishWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}
  alias Toscanini.Clients.VoxIngest

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    pipeline  = Repo.get!(Pipeline, pid)
    collect   = Pipeline.get_results(pipeline)["collect"]
    json_path = collect["json"]
    json_data = json_path |> File.read!() |> Jason.decode!()

    slug      = collect["slug"]
    published = get_in(json_data, ["metadata", "published"]) || ""
    vox_path  = build_vox_path(published, slug)

    case VoxIngest.publish_json(vox_path, json_data) do
      {:ok, _body} ->
        Pipeline.save_result(pipeline, "publish", %{"done" => true, "vox_path" => vox_path})
        Dispatcher.advance(pid)
        :ok

      {:error, reason} ->
        Pipeline.fail(pipeline, reason)
        {:error, reason}
    end
  end

  defp build_vox_path(published, slug) do
    date_str = String.slice(published, 0, 10)

    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        {_iso_year, week} = :calendar.iso_week_number({date.year, date.month, date.day})
        year  = date.year
        month = date.month |> to_string() |> String.pad_leading(2, "0")
        week  = week |> to_string() |> String.pad_leading(2, "0")
        "#{year}/#{month}/W#{week}/#{slug}.md"

      {:error, _} ->
        # Fallback sem data
        "unknown/#{slug}.md"
    end
  end
end
