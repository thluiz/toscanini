defmodule HermesOrchestrator.Collectors.Pocketcasts do
  @outdir "/home/hermes/collected"

  def collect(url, outdir \\ @outdir) do
    with {:ok, meta}      <- fetch_metadata(url),
         {:ok, mp3_path}  <- download_audio(meta.audio_url, outdir, meta.slug),
         {:ok, duration}  <- get_duration(meta, mp3_path),
         meta             <- Map.put(meta, :duration_secs, duration),
         {:ok, json_path} <- write_json(outdir, meta) do
      {:ok, %{
        "mp3"           => mp3_path,
        "json"          => json_path,
        "slug"          => meta.slug,
        "title"         => meta.title,
        "podcast"       => meta.podcast,
        "duration_secs" => duration,
        "source_url"    => url
      }}
    end
  end

  defp fetch_metadata(url) do
    case Req.get(url, headers: [{"user-agent", "Mozilla/5.0"}]) do
      {:ok, %{status: 200, body: html}} -> parse_episode(html, url)
      {:ok, %{status: s}}               -> {:error, "HTTP #{s}"}
      {:error, e}                        -> {:error, inspect(e)}
    end
  end

  defp parse_episode(html, source_url) do
    {:ok, doc} = Floki.parse_document(html)

    title       = og(doc, "og:title") || "unknown"
    audio_url   = og(doc, "og:audio")
    podcast     = og(doc, "og:site_name")
    description = og(doc, "og:description")

    episode_uuid =
      case Regex.run(~r{pca\.st/episode/([^/?]+)}, source_url) do
        [_, uuid] -> uuid
        _         -> nil
      end

    jsonld = parse_jsonld(doc)

    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    slug =
      if episode_uuid,
        do: "#{slug}-#{String.slice(episode_uuid, 0, 8)}",
        else: slug

    meta = %{
      title:        title,
      audio_url:    audio_url,
      podcast:      podcast,
      description:  description,
      uuid:         episode_uuid,
      published:    jsonld["datePublished"],
      author:       jsonld["author"],
      duration_iso: jsonld["duration"],
      slug:         slug,
      source_url:   source_url
    }

    if audio_url,
      do:  {:ok, meta},
      else: {:error, "og:audio not found in page"}
  end

  defp og(doc, property) do
    doc
    |> Floki.find("meta[property='#{property}']")
    |> Floki.attribute("content")
    |> List.first()
  end

  defp parse_jsonld(doc) do
    doc
    |> Floki.find("script[type='application/ld+json']")
    |> Enum.find_value(%{}, fn node ->
      text = Floki.text(node)
      case Jason.decode(text) do
        {:ok, map} when is_map(map) -> map
        _                           -> nil
      end
    end)
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

  defp get_duration(%{duration_iso: iso}, _path) when is_binary(iso) and iso != "" do
    {:ok, parse_iso_duration(iso)}
  end

  defp get_duration(_meta, path) do
    case System.cmd("ffprobe",
           ["-v", "quiet", "-print_format", "json", "-show_format", path],
           stderr_to_stdout: true) do
      {out, 0} ->
        dur =
          out
          |> Jason.decode!()
          |> get_in(["format", "duration"])
          |> then(fn
            nil -> nil
            d   -> d |> Float.parse() |> elem(0) |> trunc()
          end)

        {:ok, dur}

      _ ->
        {:ok, nil}
    end
  end

  defp parse_iso_duration(iso) do
    h = case Regex.run(~r/(\d+)H/, iso) do
      [_, n] -> String.to_integer(n)
      _      -> 0
    end
    m = case Regex.run(~r/(\d+)M/, iso) do
      [_, n] -> String.to_integer(n)
      _      -> 0
    end
    s = case Regex.run(~r/(\d+)S/, iso) do
      [_, n] -> String.to_integer(n)
      _      -> 0
    end
    h * 3600 + m * 60 + s
  end

  defp write_json(outdir, meta) do
    json_path    = Path.join(outdir, "#{meta.slug}.json")
    duration_str = format_duration(meta[:duration_secs])

    data = %{
      "version"  => 1,
      "metadata" => %{
        "podcast"      => meta.podcast,
        "podcast_uuid" => nil,
        "author"       => meta.author,
        "published"    => meta.published,
        "duration"     => duration_str,
        "uuid"         => meta.uuid,
        "source_url"   => meta.source_url,
        "source"       => "pocketcasts"
      },
      "transcript" => nil
    }

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
