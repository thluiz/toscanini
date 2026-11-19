defmodule Toscanini.Collectors.YoutubeFeed do
  @moduledoc """
  Feed de um canal do YouTube para as assinaturas (`Toscanini.Feeds`). Lê o Atom
  da playlist de vídeos longos do canal (`UULF<id>`): fica de fora Shorts (só no
  feed `channel_id=UC…`) e lives (playlist `UULV…`, feed próprio).

  Devolve os episódios no mesmo formato de `Pocketcasts.fetch_podcast_episodes/2`
  (`"uuid"` = videoId, `"published"`, `"title"`), para o resto de `Feeds` (watermark,
  `new_episodes/2`, `infer_check_days/1`) não distinguir a origem.

  O feed não devolve `ETag`/`Last-Modified` (só `Cache-Control: max-age=900`); o GET
  condicional fica por simetria com o Pocket Casts, mas na prática nunca dá 304.

  Seams de teste: `opts[:fetch]` (fn url, headers -> {:ok, %{status, body, headers}}
  | {:error, e}) e `opts[:runner]` (fn args -> {output, exit_code}), com default
  para `Req` e `System.cmd(yt-dlp, ...)`.
  """

  require Logger
  require Record

  Record.defrecordp(:xml_element, :xmlElement, Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl"))
  Record.defrecordp(:xml_text, :xmlText, Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl"))

  @feed_base "https://www.youtube.com/feeds/videos.xml"
  @channel_re ~r/\AUC[A-Za-z0-9_-]{22}\z/
  @ytdlp_timeout_ms 60_000

  # ---- Feed -------------------------------------------------------------------

  @doc "URL do feed Atom de vídeos longos (`UULF…`) do canal `UC…`."
  def feed_url("UC" <> rest), do: "#{@feed_base}?playlist_id=UULF#{rest}"

  @doc """
  Busca o feed do canal. Devolve `{:ok, %{episodes:, podcast_info:, etag:,
  last_modified:}}`, `{:not_modified, %{etag:, last_modified:}}` ou `{:error, reason}`.
  """
  def fetch_channel_episodes(channel_id, opts \\ []) do
    headers =
      [{"user-agent", "Mozilla/5.0"}]
      |> maybe_header("if-none-match", Keyword.get(opts, :etag))
      |> maybe_header("if-modified-since", Keyword.get(opts, :last_modified))

    fetch = Keyword.get(opts, :fetch, &default_fetch/2)

    case fetch.(feed_url(channel_id), headers) do
      {:ok, %{status: 304} = resp} ->
        {:not_modified, cache_headers(resp)}

      {:ok, %{status: 200, body: body} = resp} when is_binary(body) ->
        case parse_feed(body) do
          {:ok, parsed} -> {:ok, Map.merge(cache_headers(resp), parsed)}
          {:error, _} = e -> e
        end

      {:ok, %{status: s}} ->
        {:error, "youtube feed HTTP #{s}"}

      {:error, e} ->
        {:error, inspect(e)}
    end
  end

  defp default_fetch(url, headers) do
    Req.get(url, headers: headers, retry: false, decode_body: false)
  end

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, _name, ""), do: headers
  defp maybe_header(headers, name, value), do: [{name, value} | headers]

  defp cache_headers(resp) do
    headers = Map.get(resp, :headers, %{})

    %{
      etag:          header(headers, "etag"),
      last_modified: header(headers, "last-modified")
    }
  end

  defp header(headers, name) when is_map(headers), do: headers |> Map.get(name, []) |> List.wrap() |> List.first()

  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(to_string(k)) == name, do: v end)
  end

  defp header(_, _), do: nil

  @doc """
  Parse puro do Atom. O `<title>` do topo do feed é literalmente `Videos`: o nome
  do canal vem de `<author><name>`. O `<published>` do topo é do canal; só os de
  dentro de `<entry>` contam.
  """
  def parse_feed(xml) when is_binary(xml) do
    # xmerl decodifica conforme o encoding da declaração XML (UTF-8): recebe os
    # bytes crus, não codepoints (com codepoints, "í" dá :bad_character). O texto
    # sai como lista de codepoints.
    {doc, _rest} =
      xml
      |> :binary.bin_to_list()
      |> :xmerl_scan.string(quiet: true)

    feed_children = children(doc)

    episodes =
      feed_children
      |> Enum.filter(&(name(&1) == "entry"))
      |> Enum.map(fn entry ->
        kids = children(entry)

        %{
          "uuid"      => child_text(kids, "yt:videoId"),
          "published" => child_text(kids, "published"),
          "title"     => child_text(kids, "title")
        }
      end)
      |> Enum.reject(&is_nil(&1["uuid"]))

    channel_name =
      case Enum.find(feed_children, &(name(&1) == "author")) do
        nil -> nil
        author -> child_text(children(author), "name")
      end

    {:ok,
     %{
       episodes: episodes,
       podcast_info: %{
         title:      channel_name,
         channel_id: child_text(feed_children, "yt:channelId")
       }
     }}
  catch
    :exit, reason -> {:error, "youtube feed XML inválido: #{inspect(reason) |> String.slice(0, 200)}"}
  end

  defp children(el) when Record.is_record(el, :xmlElement), do: Enum.filter(xml_element(el, :content), &Record.is_record(&1, :xmlElement))

  defp name(el), do: el |> xml_element(:name) |> Atom.to_string()

  defp child_text(kids, tag) do
    case Enum.find(kids, &(name(&1) == tag)) do
      nil ->
        nil

      el ->
        el
        |> xml_element(:content)
        |> Enum.filter(&Record.is_record(&1, :xmlText))
        |> Enum.map_join(fn t -> t |> xml_text(:value) |> IO.chardata_to_string() end)
        |> String.trim()
        |> case do
          "" -> nil
          s -> s
        end
    end
  end

  # ---- URLs -------------------------------------------------------------------

  @doc "URL submetível ao pipeline (collector `youtube`)."
  def episode_url(video_id), do: "https://www.youtube.com/watch?v=#{video_id}"

  @doc "true para URL de youtube.com / youtu.be."
  def youtube_url?(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{host: host} when is_binary(host) ->
        host = String.downcase(host)
        host in ["youtube.com", "youtu.be"] or String.ends_with?(host, ".youtube.com")

      _ ->
        false
    end
  end

  def youtube_url?(_), do: false

  @doc "true para um channel id `UC…` (24 caracteres)."
  def channel_id?(ref) when is_binary(ref), do: Regex.match?(@channel_re, ref)
  def channel_id?(_), do: false

  # ---- yt-dlp -----------------------------------------------------------------

  @doc """
  Resolve o channel id `UC…` de uma URL de canal (`/channel/UC…`, `@handle`,
  `/c/…`, `/user/…`) ou de vídeo (`watch?v=`, `youtu.be/ID`, `/live/ID`).
  `/channel/UC…` sai direto, sem yt-dlp; o resto vai pelo yt-dlp em modo flat.

  Em modo flat, numa página de canal só `playlist_channel_id` vem preenchido e
  num vídeo só `channel_id` (o outro sai `NA`): imprime os dois e pega o
  primeiro `UC…`.
  """
  def resolve_channel_id(url, opts \\ [])

  def resolve_channel_id(url, opts) when is_binary(url) do
    url = String.trim(url)

    cond do
      channel_id?(url) ->
        {:ok, url}

      m = Regex.run(~r"/channel/(UC[A-Za-z0-9_-]{22})(?:[/?#]|\z)", url) ->
        {:ok, Enum.at(m, 1)}

      youtube_url?(url) ->
        args = ["--flat-playlist", "--playlist-items", "1", "--no-warnings",
                "--print", "playlist_channel_id", "--print", "channel_id", url]

        case run_ytdlp(args, opts) do
          {:ok, output, 0} ->
            output
            |> String.split(~r/\s+/, trim: true)
            |> Enum.find(&channel_id?/1)
            |> case do
              nil -> {:error, "yt-dlp não devolveu channel id para #{url}: #{String.slice(output, 0, 300)}"}
              id -> {:ok, id}
            end

          {:ok, output, code} ->
            {:error, "yt-dlp falhou ao resolver canal (exit #{code}): #{String.slice(output, 0, 300)}"}

          {:error, reason} ->
            {:error, "yt-dlp falhou ao resolver canal: #{inspect(reason)}"}
        end

      true ->
        {:error, :not_youtube_url}
    end
  end

  def resolve_channel_id(_, _), do: {:error, :missing_feed_ref}

  @doc """
  true se o vídeo é estreia/live agendada ou ao vivo (`live_status` =
  `is_upcoming`/`is_live`). **Fail-open**: exit ≠ 0, timeout ou saída inesperada
  → false (com warning), pra um yt-dlp quebrado não congelar o watermark do canal
  em silêncio; o collector falha e o CollectWorker retenta se o vídeo não existir.

  `--ignore-no-formats-error` é obrigatório: sem ele, numa estreia o yt-dlp sai
  com exit 1 ("Premieres in …") antes de imprimir o `live_status`.
  """
  def upcoming?(video_id, opts \\ []) do
    args = ["--skip-download", "--no-warnings", "--ignore-no-formats-error",
            "--print", "live_status", episode_url(video_id)]

    case run_ytdlp(args, opts) do
      {:ok, output, 0} ->
        lines = String.split(output, ~r/\s+/, trim: true)

        cond do
          Enum.any?(lines, &(&1 in ["is_upcoming", "is_live"])) ->
            true

          Enum.any?(lines, &(&1 in ["not_live", "was_live", "post_live"])) ->
            false

          true ->
            Logger.warning("[YoutubeFeed] live_status inesperado p/ #{video_id}: #{String.slice(output, 0, 200)}")
            false
        end

      {:ok, output, code} ->
        Logger.warning("[YoutubeFeed] live_status falhou p/ #{video_id} (exit #{code}): #{String.slice(output, 0, 200)}")
        false

      {:error, reason} ->
        Logger.warning("[YoutubeFeed] live_status falhou p/ #{video_id}: #{inspect(reason)}")
        false
    end
  end

  # Roda o yt-dlp (ou o runner injetado) com timeout. {:ok, output, exit} | {:error, reason}.
  defp run_ytdlp(args, opts) do
    runner = Keyword.get(opts, :runner, &default_runner/1)
    timeout = Keyword.get(opts, :timeout, @ytdlp_timeout_ms)
    task = Task.async(fn -> runner.(args) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, code}} -> {:ok, output, code}
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  defp default_runner(args) do
    System.cmd(ytdlp_bin(), args, stderr_to_stdout: true)
  rescue
    e -> {Exception.message(e), 127}
  end

  defp ytdlp_bin do
    System.get_env("TOSCANINI_YTDLP_BIN") || "/home/hermes/.local/bin/yt-dlp"
  end
end
