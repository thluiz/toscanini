defmodule Toscanini.Workers.NotifyWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}
  alias Toscanini.Clients.GossipGate

  # Telegram HTML message limit
  @max_chars 4000
  @vox_base_url "https://vox.thluiz.com"

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    pipeline  = Repo.get!(Pipeline, pid)
    collect   = Pipeline.get_results(pipeline)["collect"]
    publish   = Pipeline.get_results(pipeline)["publish"] || %{}
    json_path = collect["json"]
    json_data = json_path |> File.read!() |> Jason.decode!()

    title       = json_data["title"] || collect["title"] || "Episódio"
    podcast     = get_in(json_data, ["metadata", "podcast"]) || ""
    duration    = get_in(json_data, ["metadata", "duration"]) || ""
    description = json_data["description"] || ""
    timeline    = json_data["timeline"] || []
    vox_path    = publish["vox_path"]

    msg = build_message(title, podcast, duration, description, timeline, vox_path)
    GossipGate.send(msg)

    Pipeline.save_result(pipeline, "notify", %{"done" => true})
    Dispatcher.advance(pid)
    :ok
  end

  defp build_message(title, podcast, duration, description, timeline, vox_path) do
    header = """
    ✅ <b>#{escape(title)}</b>
    <i>#{escape(podcast)}#{if duration != "", do: " · #{escape(duration)}", else: ""}</i>
    """

    desc_block =
      if description != "",
        do: "\n#{escape(description)}\n",
        else: ""

    path_block =
      if vox_path,
        do: "\n📄 <code>#{escape(vox_path)}</code>\n",
        else: ""

    url_block =
      if vox_path do
        url = "#{@vox_base_url}/#{String.replace_suffix(vox_path, ".md", "")}"
        "\n🔗 <a href=\"#{url}\">#{escape(url)}</a>\n"
      else
        ""
      end

    timeline_block = build_timeline(timeline)

    base = header <> desc_block <> path_block <> url_block
    full = base <> timeline_block

    if String.length(full) <= @max_chars do
      full
    else
      # Truncar timeline para caber
      available = @max_chars - String.length(base) - 30
      truncated = String.slice(timeline_block, 0, available) <> "\n<i>…</i>"
      base <> truncated
    end
  end

  defp build_timeline([]), do: ""

  defp build_timeline(timeline) do
    items =
      timeline
      |> Enum.map(fn entry ->
        time  = entry["time"] || ""
        topic = entry["topic"] || ""
        "• <code>#{escape(time)}</code> #{escape(topic)}"
      end)
      |> Enum.join("\n")

    "\n<b>Linha do tempo:</b>\n#{items}"
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
