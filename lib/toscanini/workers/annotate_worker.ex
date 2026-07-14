defmodule Toscanini.Workers.AnnotateWorker do
  @moduledoc """
  Anotação automática do episódio, entre `summarize` e `enrich_tags`. Espelha o
  fluxo das skills `suggest-annotations` → `podcast-annotate`, mas sem os gates
  humanos (roda direto no pipeline):

    1. `suggest_annotations` (modelo barato) → 8–20 sugestões com timestamps
    2. `annotate` os timestamps → anotações ricas (título + descrição)
    3. mescla no campo **`annotations`** do JSON (dedup por janela de 30s vs.
       existentes, ordena por ts) — **nunca toca no `timeline`**

  Só executa quando `params.auto_annotate` é `true` (feed marcado); senão é
  no-op e apenas avança. É **não-bloqueante**: qualquer falha na vox-intelligence
  é logada e o pipeline segue publicando sem anotações (podem ser adicionadas
  depois pelas skills). Ver [[FeedSubscription]], [[Dispatcher]].
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}
  alias Toscanini.Clients.VoxIntelligence

  # Janela de coincidência (segundos): anotação nova a menos disto de uma
  # existente é descartada. Igual ao default da skill podcast-annotate.
  @window_secs 30

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    pipeline = Repo.get!(Pipeline, pid)
    params   = Pipeline.get_params(pipeline)

    if truthy?(params["auto_annotate"]) do
      run(pipeline, pid)
    else
      Dispatcher.advance(pid)
      :ok
    end
  end

  defp run(pipeline, pid) do
    json_path = Pipeline.get_results(pipeline)["collect"]["json"]
    json_data = json_path |> File.read!() |> Jason.decode!()
    transcript = json_data["transcript"]

    with true <- is_binary(transcript) and String.trim(transcript) != "",
         {:ok, %{"suggestions" => suggestions}} when suggestions != [] <-
           VoxIntelligence.suggest_annotations(episode_of(json_data)),
         bookmarks = bookmarks_of(suggestions),
         true <- bookmarks != [],
         {:ok, annotated} when annotated != [] <-
           VoxIntelligence.annotate(transcript, bookmarks) do
      existing = List.wrap(json_data["annotations"])
      built    = build_annotations(annotated, suggestions)
      merged   = merge_annotations(existing, built)

      json_data = Map.put(json_data, "annotations", merged)
      File.write!(json_path, Jason.encode!(json_data, pretty: true))

      added = length(merged) - length(existing)
      Logger.info("[Annotate] pipeline #{pid}: #{length(suggestions)} sugerida(s), #{added} nova(s)")
      Pipeline.save_result(pipeline, "annotate", %{
        "done" => true, "suggested" => length(suggestions), "added" => added
      })
      Dispatcher.advance(pid)
      :ok
    else
      # Nada a anotar (sem transcript/sugestões) ou falha na vox-intelligence:
      # não bloqueia a publicação — segue sem anotações.
      other ->
        Logger.warning("[Annotate] pipeline #{pid}: pulando anotação (#{inspect(other)})")
        Pipeline.save_result(pipeline, "annotate", %{"done" => true, "added" => 0, "skipped" => inspect(other)})
        Dispatcher.advance(pid)
        :ok
    end
  end

  # ---- Construção dos objetos -----------------------------------------------

  defp episode_of(json_data) do
    %{
      "transcript"   => json_data["transcript"],
      "metadata"     => json_data["metadata"] || %{},
      "summary"      => json_data["summary"],
      "lang"         => json_data["lang"],
      "participants" => participants_of(json_data),
      "annotations"  => List.wrap(json_data["annotations"])
    }
  end

  defp participants_of(json_data) do
    get_in(json_data, ["frontmatter", "participants"]) || json_data["participants"] || []
  end

  defp bookmarks_of(suggestions) do
    suggestions
    |> Enum.map(& &1["ts"])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&%{"time" => &1})
  end

  # Monta a anotação final a partir do resultado do annotate (time/title/
  # description), com campo `ts` e descrição em linha única. Enriquece com
  # `key_quotes` a partir da sugestão de mesmo timestamp, quando houver.
  defp build_annotations(annotated, suggestions) do
    quotes_by_ts =
      suggestions
      |> Enum.map(fn s -> {to_seconds(s["ts"]), s["quote"]} end)
      |> Map.new()

    Enum.map(annotated, fn a ->
      raw_ts = a["time"] || a["ts"]
      base = %{
        "ts"          => normalize_ts(raw_ts),
        "title"       => a["title"],
        "description" => single_line(a["description"])
      }

      case Map.get(quotes_by_ts, to_seconds(raw_ts)) do
        q when is_binary(q) and q != "" -> Map.put(base, "key_quotes", [q])
        _ -> base
      end
    end)
  end

  # ---- Merge / dedup ---------------------------------------------------------

  defp merge_annotations(existing, new) do
    existing_secs = Enum.map(existing, &to_seconds(annotation_ts(&1)))

    kept =
      Enum.filter(new, fn a ->
        s = to_seconds(a["ts"])
        not Enum.any?(existing_secs, fn es -> abs(es - s) < @window_secs end)
      end)

    (existing ++ kept)
    |> Enum.sort_by(fn a -> to_seconds(annotation_ts(a)) end)
  end

  defp annotation_ts(a), do: a["ts"] || a["time"] || "00:00:00"

  # ---- Helpers de tempo/texto ------------------------------------------------

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

  defp normalize_ts(ts) do
    total = to_seconds(ts)
    h = div(total, 3600)
    m = div(rem(total, 3600), 60)
    s = rem(total, 60)

    [h, m, s]
    |> Enum.map(&(&1 |> Integer.to_string() |> String.pad_leading(2, "0")))
    |> Enum.join(":")
  end

  # Descrição em linha única (invariante do render-from-json.py): sem \n internos.
  defp single_line(nil), do: ""
  defp single_line(str) when is_binary(str) do
    str |> String.replace(~r/\s*\n\s*/, " ") |> String.trim()
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false
end
