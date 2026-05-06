defmodule Toscanini.Collectors.Youtube do
  @moduledoc """
  Collector para vídeos do YouTube. Usa yt-dlp via System.cmd para extrair
  metadata e baixar áudio (mp3), gerando o mesmo schema que o collector
  Pocketcasts: <slug>.mp3 + <slug>.json em TOSCANINI_COLLECTED_DIR.

  Configurável via env: TOSCANINI_YTDLP_BIN (default /home/hermes/.local/bin/yt-dlp).
  """

  require Logger

  @print_fields ~w[id title channel channel_id channel_url uploader timestamp upload_date duration description categories tags webpage_url thumbnail language]

  def collect(url, outdir \\ nil) do
    outdir = outdir || Application.get_env(:toscanini, :collected_dir)

    with {:ok, info}       <- fetch_metadata(url),
         {:ok, meta}       <- build_meta(info, url),
         :ok               <- File.mkdir_p(outdir),
         {:ok, audio_path} <- download_audio(url, outdir, meta.slug),
         {:ok, json_path}  <- write_json(outdir, meta) do
      {:ok, %{
        "audio"         => audio_path,
        "json"          => json_path,
        "slug"          => meta.slug,
        "title"         => meta.title,
        "podcast"       => meta.podcast,
        "duration_secs" => meta.duration_secs,
        "source_url"    => url
      }}
    end
  end

  # Extensões aceites pelo yt-dlp para `bestaudio` no YouTube. Ordem
  # reflete preferência (webm/Opus é o mais comum).
  @audio_extensions ~w[webm m4a opus mp4 mp3 ogg wav]

  defp ytdlp_bin do
    System.get_env("TOSCANINI_YTDLP_BIN") || "/home/hermes/.local/bin/yt-dlp"
  end

  # 1. Extrai metadata via --print + JSON template, sem baixar nada
  defp fetch_metadata(url) do
    fields = Enum.join(@print_fields, ",")
    template = "%(.{#{fields}})j"

    case System.cmd(ytdlp_bin(), [
      "--skip-download",
      "--no-warnings",
      "--no-playlist",
      "--print", template,
      url
    ], stderr_to_stdout: true) do
      {output, 0} ->
        # yt-dlp pode emitir avisos em stderr (mistos com stdout); pegar a
        # última linha que parse-a como JSON.
        line =
          output
          |> String.split("\n", trim: true)
          |> Enum.reverse()
          |> Enum.find(fn l ->
            case Jason.decode(l) do
              {:ok, m} when is_map(m) -> true
              _ -> false
            end
          end)

        case line && Jason.decode(line) do
          {:ok, data} -> {:ok, data}
          _ -> {:error, "yt-dlp não retornou JSON parseable: #{String.slice(output, 0, 500)}"}
        end

      {output, exit_code} ->
        {:error, "yt-dlp metadata failed (exit #{exit_code}): #{String.slice(output, 0, 500)}"}
    end
  end

  @doc false
  def build_meta(info, source_url) do
    title =
      (info["title"] || "unknown")
      |> String.replace(~r/[\r\n]+/, " ")
      |> String.trim()

    slug =
      title
      |> String.downcase()
      |> String.normalize(:nfd)
      |> String.replace(~r/[^a-z0-9 ]+/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")
      |> String.slice(0, 80)

    if slug == "" do
      {:error, "slug vazio para vídeo: #{source_url}"}
    else
      categories_str =
        case info["categories"] do
          list when is_list(list) and list != [] -> Enum.join(list, "\n")
          _ -> nil
        end

      published =
        cond do
          is_integer(info["timestamp"]) ->
            info["timestamp"] |> DateTime.from_unix!() |> DateTime.to_iso8601()

          match?(<<_::binary-size(8)>>, info["upload_date"]) ->
            <<y::binary-size(4), m::binary-size(2), d::binary-size(2)>> = info["upload_date"]
            "#{y}-#{m}-#{d}T00:00:00Z"

          true ->
            nil
        end

      duration_secs =
        case info["duration"] do
          n when is_number(n) -> trunc(n)
          _ -> nil
        end

      meta = %{
        title:              title,
        slug:               slug,
        podcast:            info["channel"] || info["uploader"],
        author:             info["uploader"] || info["channel"],
        uuid:               info["id"],
        podcast_uuid:       info["channel_id"],
        podcast_url:        info["channel_url"],
        podcast_categories: categories_str,
        podcast_show_type:  "video",
        published:          published,
        duration_secs:      duration_secs,
        description:        info["description"],
        thumbnail:          info["thumbnail"],
        language:           info["language"],
        source_url:         source_url
      }

      {:ok, meta}
    end
  end

  defp download_audio(url, outdir, slug) do
    case find_cached_audio(outdir, slug) do
      cached when is_binary(cached) ->
        Logger.info("[Youtube] audio já existe, reusando: #{cached}")
        {:ok, cached}

      nil ->
        template = Path.join(outdir, "#{slug}.%(ext)s")

        case System.cmd(ytdlp_bin(), [
          "-f", "bestaudio",
          "--print", "after_move:filepath",
          "--no-warnings",
          "--no-playlist",
          "-o", template,
          url
        ], stderr_to_stdout: true) do
          {output, 0} ->
            # Última linha do stdout que aponta para um arquivo existente.
            path =
              output
              |> String.split("\n", trim: true)
              |> Enum.reverse()
              |> Enum.find(&File.exists?/1)

            if path,
              do: {:ok, path},
              else: {:error, "yt-dlp completou sem reportar filepath: #{String.slice(output, 0, 500)}"}

          {output, exit_code} ->
            {:error, "yt-dlp download failed (exit #{exit_code}): #{String.slice(output, 0, 500)}"}
        end
    end
  end

  defp find_cached_audio(outdir, slug) do
    Enum.find_value(@audio_extensions, fn ext ->
      path = Path.join(outdir, "#{slug}.#{ext}")
      if File.exists?(path), do: path
    end)
  end

  @doc false
  def write_json(outdir, meta) do
    json_path = Path.join(outdir, "#{meta.slug}.json")

    existing =
      case File.read(json_path) do
        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end
        _ -> %{}
      end

    fresh_metadata = %{
      "podcast"            => meta.podcast,
      "podcast_uuid"       => meta.podcast_uuid,
      "podcast_site"       => meta.podcast_url,
      "podcast_type"       => meta.podcast_show_type,
      "podcast_categories" => meta.podcast_categories,
      "title"              => meta.title,
      "author"             => meta.author,
      "published"          => meta.published,
      "duration"           => format_duration(meta.duration_secs),
      "uuid"               => meta.uuid,
      "source_url"         => meta.source_url,
      "source"             => "youtube",
      "thumbnail"          => meta.thumbnail
    }

    merged_metadata =
      Map.merge(
        Map.get(existing, "metadata", %{}),
        Map.reject(fresh_metadata, fn {_, v} -> is_nil(v) end)
      )

    fresh_top =
      %{"description" => meta.description, "lang" => meta.language}
      |> Map.reject(fn {_, v} -> is_nil(v) end)

    data =
      existing
      |> Map.merge(%{"version" => 1, "metadata" => merged_metadata})
      |> then(fn m ->
        # Só preenche description/lang se ainda não existirem (preserva
        # output de summarize em re-runs).
        Enum.reduce(fresh_top, m, fn {k, v}, acc -> Map.put_new(acc, k, v) end)
      end)
      |> Map.put_new("transcript", nil)

    File.write!(json_path, Jason.encode!(data, pretty: true))
    {:ok, json_path}
  end

  defp format_duration(nil), do: nil

  defp format_duration(secs) do
    h = div(secs, 3600)
    m = secs |> rem(3600) |> div(60)
    s = rem(secs, 60)
    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> to_string()
  end
end
