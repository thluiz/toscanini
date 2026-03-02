defmodule Toscanini.Collectors.Pocketcasts do
  @api_base "https://podcast-api.pocketcasts.com"

  def collect(url, outdir \\ nil) do
    outdir = outdir || Application.get_env(:toscanini, :collected_dir)

    with {:ok, meta}      <- fetch_metadata(url),
         {:ok, mp3_path}  <- download_audio(meta.audio_url, outdir, meta.slug),
         {:ok, json_path} <- write_json(outdir, meta) do
      {:ok, %{
        "mp3"           => mp3_path,
        "json"          => json_path,
        "slug"          => meta.slug,
        "title"         => meta.title,
        "podcast"       => meta.podcast,
        "duration_secs" => meta.duration_secs,
        "source_url"    => url
      }}
    end
  end

  # 1. Seguir redirect para URL canónica com UUIDs (sem descarregar o body da página)
  defp fetch_metadata(url) do
    with {:ok, final_url}                  <- resolve_url(url),
         {:ok, podcast_uuid, episode_uuid} <- extract_uuids(final_url),
         {:ok, ep, podcast_info} <- fetch_episode(podcast_uuid, episode_uuid) do
      build_meta(ep, final_url, podcast_uuid, podcast_info)
    end
  end

  # Segue redirects manualmente via Location header (até 5 saltos).
  # Evita descarregar body de páginas SPA que podem retornar 4xx/5xx.
  defp resolve_url(url, depth \\ 0)
  defp resolve_url(_url, 5), do: {:error, "too many redirects"}

  defp resolve_url(url, depth) do
    opts = [headers: [{"user-agent", "Mozilla/5.0"}], redirect: false, retry: false]

    case Req.get(url, opts) do
      {:ok, %{status: s, headers: headers}} when s in [301, 302, 303, 307, 308] ->
        loc = List.first(headers["location"] || [])

        if loc do
          # Suporta Location relativo
          next =
            if String.starts_with?(loc, "http"),
              do: loc,
              else: URI.merge(URI.parse(url), loc) |> URI.to_string()

          resolve_url(next, depth + 1)
        else
          {:error, "redirect (#{s}) sem header Location de #{url}"}
        end

      {:ok, _} ->
        # 200 ou outro — URL atual é a final
        {:ok, url}

      {:error, e} ->
        {:error, inspect(e)}
    end
  end

  # Extrai podcast_uuid (1º UUID) e episode_uuid (último UUID) da URL final
  defp extract_uuids(url) do
    uuids =
      ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/
      |> Regex.scan(url)
      |> List.flatten()

    case uuids do
      [_ | _] -> {:ok, List.first(uuids), List.last(uuids)}
      []      -> {:error, "nenhum UUID na URL: #{url}"}
    end
  end

  # 2. Chamar API PocketCasts → CDN (redirect automático) → JSON com episódios
  # Req descomprime gzip e faz JSON decode automaticamente.
  defp fetch_episode(podcast_uuid, episode_uuid) do
    opts = [headers: [{"user-agent", "Mozilla/5.0"}]]

    case Req.get("#{@api_base}/podcast/full/#{podcast_uuid}", opts) do
      {:ok, %{status: 200, body: data}} ->
        parsed = ensure_map(data)
        podcast = parsed["podcast"] || %{}
        podcast_info = %{
          title:     podcast["title"],
          author:    podcast["author"],
          url:       podcast["url"],
          category:  podcast["category"],
          show_type: podcast["show_type"]
        }
        episodes = podcast["episodes"] || []

        case Enum.find(episodes, &(&1["uuid"] == episode_uuid)) do
          nil -> {:error, "episódio #{episode_uuid} não encontrado no feed"}
          ep  -> {:ok, ep, podcast_info}
        end

      {:ok, %{status: s}} ->
        {:error, "podcast API HTTP #{s}"}

      {:error, e} ->
        {:error, inspect(e)}
    end
  end

  # Suporta tanto body já decodificado (map) quanto binary (gzip ou JSON raw)
  defp ensure_map(data) when is_map(data), do: data

  defp ensure_map(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, map} -> map
      {:error, _} -> :zlib.gunzip(data) |> Jason.decode!()
    end
  end

  defp build_meta(ep, source_url, podcast_uuid, podcast_info) do
    title     = (ep["title"] || "unknown") |> String.replace(~r/[\r\n]+/, " ") |> String.trim()
    audio_url = ep["url"]
    dur_secs  = ep["duration"] |> then(&if(is_number(&1), do: trunc(&1), else: nil))
    published = ep["published"]
    author    = ep["author"] || podcast_info.author
    podcast   = ep["podcastTitle"] || podcast_info.title

    slug =
      title
      |> String.downcase()
      |> String.normalize(:nfd)
      |> String.replace(~r/[^a-z0-9 ]+/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")
      |> String.slice(0, 80)

    meta = %{
      title:            title,
      audio_url:        audio_url,
      podcast:          podcast,
      author:           author,
      uuid:             ep["uuid"],
      podcast_uuid:     podcast_uuid,
      podcast_url:      podcast_info.url,
      podcast_category: podcast_info.category,
      podcast_show_type: podcast_info.show_type,
      published:        published,
      duration_secs:    dur_secs,
      slug:             slug,
      source_url:       source_url
    }

    if audio_url, do: {:ok, meta}, else: {:error, "episódio sem URL de áudio"}
  end

  defp download_audio(audio_url, outdir, slug) do
    path = Path.join(outdir, "#{slug}.mp3")
    File.mkdir_p!(outdir)

    case Req.get(audio_url, into: File.stream!(path), max_redirects: 5) do
      {:ok, %{status: 200}} -> {:ok, path}
      {:ok, %{status: s}}   -> {:error, "download HTTP #{s}"}
      {:error, e}           -> {:error, inspect(e)}
    end
  end

  defp write_json(outdir, meta) do
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

    # Campos frescos da API — nil significa "não disponível": preservar existente
    fresh_metadata = %{
      "podcast"            => meta.podcast,
      "podcast_uuid"       => meta.podcast_uuid,
      "podcast_site"       => meta.podcast_url,
      "podcast_type"       => meta.podcast_show_type,
      "podcast_categories" => meta.podcast_category,
      "title"              => meta.title,
      "author"             => meta.author,
      "published"          => meta.published,
      "duration"           => format_duration(meta.duration_secs),
      "uuid"               => meta.uuid,
      "source_url"         => meta.source_url,
      "source"             => "pocketcasts"
    }

    # Frescos não-nil têm prioridade; nil preserva o valor existente
    merged_metadata =
      Map.merge(
        Map.get(existing, "metadata", %{}),
        Map.reject(fresh_metadata, fn {_, v} -> is_nil(v) end)
      )

    # Preservar todos os campos existentes (title/lang/summary/etc. do summarize)
    # Só sobrescrever version e metadata com dados frescos
    data =
      existing
      |> Map.merge(%{"version" => 1, "metadata" => merged_metadata})
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
