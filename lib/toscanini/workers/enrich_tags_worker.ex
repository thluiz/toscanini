defmodule Toscanini.Workers.EnrichTagsWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher, ParticipantAliases}

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    pipeline  = Repo.get!(Pipeline, pid)
    collect   = Pipeline.get_results(pipeline)["collect"]
    json_path = collect["json"]

    # Grafia canônica antes de derivar as tags de participante
    aliases =
      System.fetch_env!("TOSCANINI_VOX_CONTENT_DIR")
      |> ParticipantAliases.path()
      |> ParticipantAliases.load()

    {json_data, renamed} =
      json_path |> File.read!() |> Jason.decode!() |> ParticipantAliases.normalize(aliases)

    existing_tags  = json_data["tags"] || []
    participants   = json_data["participants"] || []
    podcast        = get_in(json_data, ["metadata", "podcast"])
    categories     = get_in(json_data, ["metadata", "podcast_categories"]) |> split_categories()

    new_tags =
      (participants ++ List.wrap(podcast) ++ categories)
      |> Enum.map(&ParticipantAliases.slug/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reject(&(&1 in existing_tags))

    updated = Map.put(json_data, "tags", existing_tags ++ new_tags)
    File.write!(json_path, Jason.encode!(updated, pretty: true))

    Pipeline.save_result(pipeline, "enrich_tags", %{"added" => new_tags, "renamed" => renamed})
    Dispatcher.advance(pid)
    :ok
  end

  defp split_categories(nil), do: []
  defp split_categories(list) when is_list(list), do: list
  defp split_categories(str) when is_binary(str) do
    str
    |> String.split(~r/[\n,;&]+/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
