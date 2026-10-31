defmodule Toscanini.Workers.NotifyWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}
  alias Toscanini.Clients.GossipGate
  alias Toscanini.Workers.BatchAdvanceWorker

  # Telegram HTML message limit
  @max_chars 4000

  @tier_icon %{"concept" => "🔑", "data" => "📊", "reflection" => "💭"}

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
    results     = Pipeline.get_results(pipeline)
    collect     = results["collect"]
    write_files = results["write_files"] || %{}
    annotate    = results["annotate"] || %{}
    json_path   = collect["json"]
    json_data   = json_path |> File.read!() |> Jason.decode!()

    title       = json_data["title"] || collect["title"] || "Episódio"
    podcast     = get_in(json_data, ["metadata", "podcast"]) || ""
    duration    = get_in(json_data, ["metadata", "duration"]) || ""
    description = json_data["description"] || ""
    timeline    = json_data["timeline"] || []
    vox_path    = write_files["vox_path"]
    new_annotations = annotate["new"] || []

    vox_base_url = Application.get_env(:toscanini, :vox_base_url, "https://vox.thluiz.com")

    if new_annotations != [] do
      # Anotação (backlog manual ou feed auto_annotate): manda a lista das
      # anotações novas — com resumo — dividida em quantas mensagens forem
      # necessárias pro limite do Telegram, com a URL completa só na última.
      url = build_url(vox_path, vox_base_url)

      new_annotations
      |> build_annotation_messages(title, podcast, duration, url)
      |> Enum.each(&GossipGate.send/1)
    else
      msg = build_message(title, podcast, duration, description, timeline, vox_path, vox_base_url)
      GossipGate.send(msg)
    end

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

  defp build_url(nil, _base), do: nil

  defp build_url(vox_path, base),
    do: "#{String.trim_trailing(base, "/")}/#{String.replace_suffix(vox_path, ".md", "")}"

  # ---- Mensagem de anotações (nova) ------------------------------------------

  defp build_annotation_messages(annotations, title, podcast, duration, url) do
    header =
      "📝 <b>#{escape(title)}</b>\n" <>
        "<i>#{escape(podcast)}#{if duration != "", do: " · #{escape(duration)}", else: ""}</i>\n" <>
        "\n#{length(annotations)} anotações adicionadas:\n\n"

    footer =
      if url, do: "\n\n🔗 <a href=\"#{escape(url)}\">#{escape(url)}</a>", else: ""

    lines =
      annotations
      |> Enum.sort_by(fn a -> to_seconds(a["ts"]) end)
      |> Enum.map(&annotation_line/1)

    chunk_messages(header, lines, footer)
  end

  defp annotation_line(a) do
    icon  = Map.get(@tier_icon, a["tier"], "📍")
    ts    = a["ts"] || ""
    title = a["title"] || ""
    desc  = a["description"] || ""

    short_desc =
      if String.length(desc) > 160 do
        String.slice(desc, 0, 160) <> "…"
      else
        desc
      end

    "#{icon} <code>#{escape(ts)}</code> — <b>#{escape(title)}</b>\n<i>#{escape(short_desc)}</i>"
  end

  # Empacota `lines` em quantas mensagens forem necessárias, repetindo
  # `header` em cada uma e só anexando `footer` (a URL) na última.
  defp chunk_messages(header, lines, footer) do
    chunks =
      Enum.reduce(lines, [""], fn line, [current | rest] ->
        candidate = if current == "", do: header <> line, else: current <> "\n\n" <> line

        if String.length(candidate) + String.length(footer) > @max_chars and current != "" do
          [header <> line, current | rest]
        else
          [candidate | rest]
        end
      end)
      |> Enum.reverse()

    total = length(chunks)

    chunks
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, i} ->
      page = if total > 1, do: "\n\n<i>(#{i}/#{total})</i>", else: ""
      body = if i == total, do: chunk <> footer, else: chunk
      body <> page
    end)
  end

  defp to_seconds(ts) when is_binary(ts) do
    ts
    |> String.split(":")
    |> Enum.map(&String.to_integer(String.trim(&1)))
    |> case do
      [h, m, s] -> h * 3600 + m * 60 + s
      [m, s]    -> m * 60 + s
      [s]       -> s
      _         -> 0
    end
  rescue
    _ -> 0
  end

  defp to_seconds(_), do: 0

  # ---- Mensagem padrão (sem anotações novas — comportamento original) -------

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
