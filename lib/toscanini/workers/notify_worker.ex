defmodule Toscanini.Workers.NotifyWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}
  alias Toscanini.Clients.GossipGate
  alias Toscanini.Workers.BatchAdvanceWorker

  # Telegram HTML message limit
  @max_chars 4000

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    pipeline = Repo.get!(Pipeline, pid)

    case pipeline.content_type do
      "scholion_quote" -> notify_scholion(pipeline, pid)
      _ -> notify_podcast(pipeline, pid)
    end
  end

  defp notify_scholion(pipeline, pid) do
    results = Pipeline.get_results(pipeline)
    synth   = results["scholion_synthesize"] || %{}
    slug       = synth["slug"]
    title      = synth["title"] || slug
    verdict    = synth["verdict"]
    draft      = synth["draft"] == true
    findings   = synth["findings"] || []
    lexical    = synth["lexical_warnings"] || []
    authorship = synth["authorship"] || %{}

    base = Application.get_env(:toscanini, :scholion_base_url, "https://scholion.thluiz.com")
    url  = "#{String.trim_trailing(base, "/")}/notes/#{slug}/"

    msg =
      if draft do
        # ghost-audit red → commitada como draft (fora do ar até corrigir).
        "🛑 <b>Scholion — barrada (ghost-audit red) → salva como DRAFT</b>\n" <>
          "<i>#{escape(title)}</i>\n" <>
          "slug: <code>#{escape(slug)}</code>\n" <>
          "Não vai ao ar até corrigir e remover <code>draft: true</code>.\n" <>
          format_findings(findings) <>
          "\n🔎 job: <code>#{escape(pipeline.id)}</code>"
      else
        flag = if verdict == "yellow", do: "\n⚠️ ghost-audit: yellow (revisar)", else: ""

        auth_flag =
          if authorship["verified"] == false,
            do: "\n🔎 autoria não verificada — conferir: #{escape(to_string(authorship["notes"]))}",
            else: ""

        lex = if lexical == [], do: "", else: "\n📝 lexical: #{escape(Enum.join(lexical, "; "))}"

        "✅ <b>#{escape(title)}</b>\n" <>
          "<i>Scholion — citação</i>#{flag}#{auth_flag}#{lex}\n" <>
          "🔗 <a href=\"#{url}\">#{escape(url)}</a>"
      end

    GossipGate.send(msg)
    Pipeline.save_result(pipeline, "notify", %{"done" => true})
    Dispatcher.advance(pid)
    :ok
  end

  defp format_findings([]), do: ""

  defp format_findings(findings) when is_list(findings) do
    items =
      findings
      |> Enum.take(8)
      |> Enum.map(fn f ->
        type = f["type"] || f["rule"] || f["severity"] || f["kind"] || ""
        msg = f["message"] || f["msg"] || f["suggestion"] || f["detail"] || inspect(f)
        prefix = if type == "", do: "", else: "#{escape(to_string(type))}: "
        "• #{prefix}#{escape(to_string(msg))}"
      end)
      |> Enum.join("\n")

    "\n<b>Findings:</b>\n#{items}\n"
  end

  defp format_findings(_), do: ""

  defp notify_podcast(pipeline, pid) do
    collect     = Pipeline.get_results(pipeline)["collect"]
    write_files = Pipeline.get_results(pipeline)["write_files"] || %{}
    json_path   = collect["json"]
    json_data   = json_path |> File.read!() |> Jason.decode!()

    title       = json_data["title"] || collect["title"] || "Episódio"
    podcast     = get_in(json_data, ["metadata", "podcast"]) || ""
    duration    = get_in(json_data, ["metadata", "duration"]) || ""
    description = json_data["description"] || ""
    timeline    = json_data["timeline"] || []
    vox_path    = write_files["vox_path"]

    vox_base_url = Application.get_env(:toscanini, :vox_base_url, "https://vox.thluiz.com")
    msg = build_message(title, podcast, duration, description, timeline, vox_path, vox_base_url)
    GossipGate.send(msg)

    Pipeline.save_result(pipeline, "notify", %{"done" => true})
    Dispatcher.advance(pid)

    # Se pertence a um batch, avançar para o próximo episódio
    params = Pipeline.get_params(pipeline)

    case {params["batch_id"], params["batch_item_id"]} do
      {nil, _} ->
        :ok

      {batch_id, item_id} when not is_nil(item_id) ->
        BatchAdvanceWorker.new(%{
          "batch_id"      => batch_id,
          "batch_item_id" => item_id,
          "result"        => "ok"
        })
        |> Oban.insert!()
    end

    :ok
  end

  defp build_message(title, podcast, duration, description, timeline, vox_path, vox_base_url) do
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
        url = "#{vox_base_url}/#{String.replace_suffix(vox_path, ".md", "")}"
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
