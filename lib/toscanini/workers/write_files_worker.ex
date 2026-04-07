defmodule Toscanini.Workers.WriteFilesWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}
  alias Toscanini.VoxPocketcastJsonRenderer

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    vox_content_dir = System.fetch_env!("TOSCANINI_VOX_CONTENT_DIR")

    pipeline  = Repo.get!(Pipeline, pid)
    collect   = Pipeline.get_results(pipeline)["collect"]
    json_path = collect["json"]
    json_data = json_path |> File.read!() |> Jason.decode!()

    slug      = collect["slug"]
    published = get_in(json_data, ["metadata", "published"]) || ""
    vox_path  = build_vox_path(published, slug)

    base_path  = Path.join(vox_content_dir, Path.rootname(vox_path))
    dest_json  = base_path <> ".json"
    dest_md    = base_path <> ".md"

    File.mkdir_p!(Path.dirname(dest_json))
    File.write!(dest_json, Jason.encode!(json_data, pretty: true))

    md_content = VoxPocketcastJsonRenderer.render(json_data, slug: slug)
    File.write!(dest_md, md_content)

    title = json_data["title"] || collect["title"] || slug

    Pipeline.save_result(pipeline, "write_files", %{
      "vox_path"  => vox_path,
      "dest_json" => dest_json,
      "dest_md"   => dest_md,
      "title"     => title
    })

    Dispatcher.advance(pid)
    :ok
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
        "unknown/#{slug}.md"
    end
  end
end
