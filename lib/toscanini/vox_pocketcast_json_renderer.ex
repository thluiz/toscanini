defmodule Toscanini.VoxPocketcastJsonRenderer do
  @moduledoc """
  Pure Elixir renderer: Toscanini podcast JSON → Markdown.
  Mirrors ~/vox/scripts/render-from-json.py (Toscanini format only).
  """

  @doc """
  Renders a decoded JSON map into a markdown string.
  """
  def render(json_map) when is_map(json_map) do
    doc = normalize(json_map)
    lang = doc.frontmatter["lang"] || "pt"
    title = doc.frontmatter["title"] || ""

    header = render_frontmatter(doc.frontmatter) <> "\n\n# #{title}"

    sections =
      []
      |> maybe_add(doc.summary != "", render_summary(doc.summary, lang))
      |> maybe_add(doc.annotations != [], render_annotations(doc.annotations, lang))
      |> maybe_add(doc.recommendations != [], render_recommendations(doc.recommendations, lang))
      |> maybe_add(doc.timeline != [], render_timeline(doc.timeline, lang))
      |> add(render_metadata(doc.metadata, doc.frontmatter, lang))
      # |> maybe_add(doc.transcript != "", render_transcript(doc.transcript, lang))  # transcript removed from MD — too heavy

    header <> "\n\n---\n\n" <> Enum.join(sections, "\n\n---\n\n") <> "\n"
  end

  # ---------------------------------------------------------------------------
  # Normalize: Toscanini flat format → internal render format
  # ---------------------------------------------------------------------------

  defp normalize(json_map) do
    metadata = json_map["metadata"] || %{}

    fm =
      %{
        "title"        => json_map["title"],
        "lang"         => json_map["lang"],
        "description"  => json_map["description"],
        "tags"         => json_map["tags"],
        "aliases"      => json_map["aliases"],
        "participants" => json_map["participants"],
        "podcast"      => metadata["podcast"],
        "uuid"         => metadata["uuid"],
        "published"    => metadata["published"],
      }
      |> Enum.reject(fn {_k, v} -> blank?(v) end)
      |> Map.new()

    timeline =
      (json_map["timeline"] || [])
      |> Enum.map(fn item ->
        ts    = item["time"] || item["ts"] || ""
        topic = item["topic"] || ""
        desc  = item["summary"] || item["description"] || ""

        full =
          cond do
            topic != "" and desc != "" -> "**#{topic}** — #{desc}"
            topic != ""                -> topic
            true                       -> desc
          end

        %{"ts" => ts, "description" => full}
      end)

    raw_rec = json_map["recommendations"] || %{}

    recommendations =
      if is_map(raw_rec) do
        raw_rec
        |> Enum.filter(fn {_k, v} -> not blank?(v) end)
        |> Enum.map(fn {cat, items} -> %{"category" => cat, "items" => items} end)
      else
        raw_rec
      end

    annotations =
      (json_map["annotations"] || [])
      |> Enum.map(fn item ->
        ts = item["time"] || item["ts"] || ""
        %{"ts" => ts, "title" => item["title"] || "", "description" => item["description"] || ""}
      end)

    %{
      frontmatter:     fm,
      summary:         json_map["summary"] || "",
      timeline:        timeline,
      recommendations: recommendations,
      annotations:     annotations,
      metadata:        metadata,
      transcript:      json_map["transcript"] || "",
    }
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(%{} = m) when map_size(m) == 0, do: true
  defp blank?(_), do: false

  # ---------------------------------------------------------------------------
  # Frontmatter YAML
  # ---------------------------------------------------------------------------

  # Field order matches Python yaml.dump(sort_keys=False) with fm dict order
  @fm_field_order ~w(title lang description tags aliases participants podcast uuid published)

  defp render_frontmatter(fm) do
    lines =
      @fm_field_order
      |> Enum.filter(&Map.has_key?(fm, &1))
      |> Enum.map(fn key -> yaml_field(key, fm[key]) end)

    "---\n" <> Enum.join(lines, "") <> "---"
  end

  defp yaml_field(key, value) when is_list(value) do
    items = Enum.map_join(value, "", fn item ->
      "- #{yaml_list_item(item)}\n"
    end)
    "#{key}:\n#{items}"
  end


  defp yaml_list_item(str) when is_binary(str) do
    if needs_quoting?(str) or String.contains?(str, "|") do
      "\"#{String.replace(str, "\"", "\\\"")}\""
    else
      str
    end
  end

  defp yaml_list_item(val), do: "#{val}"
  defp yaml_field(key, value) when is_binary(value) do
    prefix_len = String.length(key) + 2
    "#{key}: #{yaml_scalar(value, prefix_len)}\n"
  end

  defp yaml_field(key, value), do: "#{key}: #{value}\n"

  # Scalar quoting/folding rules to approximate yaml.dump behavior
  defp yaml_scalar(str, prefix_len) do
    cond do
      # ISO 8601 timestamp → single-quoted (yaml.dump would parse as datetime otherwise)
      Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, str) ->
        "'#{str}'"

      # Needs quoting due to special YAML characters
      needs_quoting?(str) ->
        "\"#{String.replace(str, "\"", "\\\"")}\""

      # Long string → wrap with continuation indent (like yaml.dump fold)
      String.length(str) + prefix_len > 80 ->
        yaml_fold(str, 80 - prefix_len)

      true ->
        str
    end
  end

  defp needs_quoting?(str) do
    String.contains?(str, ": ") or
    String.contains?(str, " #") or
      Regex.match?(~r/^[#\{\[\>\|\!&\*\?\-,]/, str) or
      str in ["true", "false", "null", "yes", "no", "on", "off"]
  end

  # Word-wrap a string starting at first_line_max chars, continuation at 78 chars (80 - 2 indent)
  defp yaml_fold(str, first_line_max) do
    words = String.split(str, " ")

    {lines, current, _first} =
      Enum.reduce(words, {[], "", true}, fn word, {lines, cur, first} ->
        max_len = if first, do: first_line_max, else: 78
        candidate = if cur == "", do: word, else: "#{cur} #{word}"

        if String.length(candidate) <= max_len do
          {lines, candidate, first}
        else
          if cur == "" do
            # Single word exceeds limit, add as-is
            {lines ++ [word], "", false}
          else
            {lines ++ [cur], word, false}
          end
        end
      end)

    all_lines = if current != "", do: lines ++ [current], else: lines

    case all_lines do
      [] -> str
      [single] -> single
      [first | rest] ->
        continuation = Enum.map_join(rest, "\n", fn line -> "  #{line}" end)
        "#{first}\n#{continuation}"
    end
  end

  # ---------------------------------------------------------------------------
  # Summary
  # ---------------------------------------------------------------------------

  defp render_summary(text, lang) do
    heading = if lang == "pt", do: "## Resumo", else: "## Summary"
    "#{heading}\n\n#{String.trim(text)}"
  end

  # ---------------------------------------------------------------------------
  # Annotations
  # ---------------------------------------------------------------------------

  defp render_annotations([], _lang), do: ""

  defp render_annotations(items, lang) do
    heading = if lang == "pt", do: "## Anotações", else: "## Bookmarks"

    lines =
      Enum.flat_map(items, fn item ->
        ts    = item["ts"] || ""
        title = item["title"] || ""
        desc  = item["description"] || ""
        line  = "- **#{ts}** — **#{title}**"
        if desc != "", do: [line, "  #{desc}"], else: [line]
      end)

    "#{heading}\n\n" <> Enum.join(lines, "\n")
  end

  # ---------------------------------------------------------------------------
  # Recommendations
  # ---------------------------------------------------------------------------

  defp render_recommendations([], _lang), do: ""

  defp render_recommendations(items, lang) do
    heading = if lang == "pt", do: "## Indicações", else: "## Recommendations"

    group_parts =
      Enum.map(items, fn group ->
        cat       = group["category"] || ""
        grp_items = group["items"] || []

        cat_header = if cat != "", do: "### #{title_case(cat)}\n\n", else: ""

        item_lines =
          Enum.map_join(grp_items, "\n", fn item ->
            t      = item["title"] || ""
            desc   = item["description"] || ""
            author = item["author"] || ""
            entry  = if author != "", do: "- *#{t}* (#{author})", else: "- *#{t}*"
            if desc != "", do: "#{entry} — #{desc}", else: entry
          end)

        cat_header <> item_lines
      end)

    "#{heading}\n\n" <> Enum.join(group_parts, "\n\n")
  end

  # ---------------------------------------------------------------------------
  # Timeline
  # ---------------------------------------------------------------------------

  defp render_timeline([], _lang), do: ""

  defp render_timeline(items, lang) do
    heading = if lang == "pt", do: "## Linha do Tempo", else: "## Topic Timeline"

    lines =
      Enum.map(items, fn item ->
        ts   = item["ts"] || ""
        desc = item["description"] || ""
        "- **#{ts}** — #{desc}"
      end)

    "#{heading}\n\n" <> Enum.join(lines, "\n")
  end

  # ---------------------------------------------------------------------------
  # Metadata (Episode + Podcast info)
  # ---------------------------------------------------------------------------

  defp render_metadata(metadata, fm, lang) do
    m = metadata

    podcast      = m["podcast"]      || fm["podcast"]
    author       = m["author"]
    categories   = m["podcast_categories"]
    published    = m["published"]
    duration     = m["duration"]
    source_url   = m["source_url"]
    uuid         = m["uuid"]         || fm["uuid"]
    podcast_name = m["podcast_name"] || m["podcast"]
    podcast_type = m["podcast_type"]
    podcast_site = m["podcast_site"]
    podcast_uuid = m["podcast_uuid"]

    has_podcast_info = podcast_name || podcast_type || podcast_site || podcast_uuid

    if lang == "pt" do
      lines = ["## Dados do Episódio", ""]
      lines = if podcast,    do: lines ++ ["- **Podcast**: #{podcast}"],       else: lines
      lines = if author,     do: lines ++ ["- **Autor**: #{author}"],          else: lines
      lines = if categories, do: lines ++ ["- **Categoria**: #{categories}"],  else: lines
      lines = if published,  do: lines ++ ["- **Publicado**: #{published}"],   else: lines
      lines = if duration,   do: lines ++ ["- **Duração**: #{duration}"],      else: lines

      lines =
        if source_url do
          lines ++ ["", "### Referências", "", "- **URL PocketCasts**: #{source_url}"]
        else
          lines
        end

      lines = if uuid, do: lines ++ ["- **UUID Episódio**: #{uuid}"], else: lines

      lines =
        if has_podcast_info do
          base = lines ++ ["", "---", "", "## Dados do Podcast", ""]
          base = if podcast_name, do: base ++ ["- **Nome**: #{podcast_name}"], else: base
          base = if podcast_type, do: base ++ ["- **Tipo**: #{podcast_type}"], else: base
          base = if podcast_site, do: base ++ ["- **Site**: #{podcast_site}"], else: base
          if podcast_uuid,        do: base ++ ["- **UUID**: #{podcast_uuid}"], else: base
        else
          lines
        end

      Enum.join(lines, "\n")
    else
      lines = ["## Episode Info", ""]
      lines = if podcast,    do: lines ++ ["- **Podcast**: #{podcast}"],      else: lines
      lines = if author,     do: lines ++ ["- **Author**: #{author}"],        else: lines
      lines = if categories, do: lines ++ ["- **Category**: #{categories}"],  else: lines
      lines = if published,  do: lines ++ ["- **Published**: #{published}"],  else: lines
      lines = if duration,   do: lines ++ ["- **Duration**: #{duration}"],    else: lines

      lines =
        if source_url do
          lines ++ ["", "### References", "", "- **URL PocketCasts**: #{source_url}"]
        else
          lines
        end

      lines = if uuid, do: lines ++ ["- **Episode UUID**: #{uuid}"], else: lines

      lines =
        if has_podcast_info do
          base = lines ++ ["", "---", "", "## Podcast Info", ""]
          base = if podcast_name, do: base ++ ["- **Name**: #{podcast_name}"],  else: base
          base = if podcast_type, do: base ++ ["- **Type**: #{podcast_type}"],  else: base
          base = if podcast_site, do: base ++ ["- **Site**: #{podcast_site}"],  else: base
          if podcast_uuid,        do: base ++ ["- **UUID**: #{podcast_uuid}"],  else: base
        else
          lines
        end

      Enum.join(lines, "\n")
    end
  end

  # ---------------------------------------------------------------------------
  # Transcript
  # ---------------------------------------------------------------------------

  defp render_transcript("", _lang), do: ""

  defp render_transcript(text, lang) do
    heading = if lang == "pt", do: "## Transcrição", else: "## Transcript"
    fixed = text |> String.trim() |> String.replace("\n[", "\n\n[")
    "#{heading}\n\n#{fixed}"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp maybe_add(sections, false, _block), do: sections
  defp maybe_add(sections, true, block), do: sections ++ [block]
  defp add(sections, block), do: sections ++ [block]

  # Mimics Python's str.title(): capitalize first letter of each "word"
  # where a word starts after any non-letter character.
  defp title_case(str) do
    parts = Regex.split(~r/([^a-zA-Z]+)/, str, include_captures: true)

    Enum.map_join(parts, "", fn part ->
      if Regex.match?(~r/^[a-zA-Z]/, part) do
        String.capitalize(part)
      else
        part
      end
    end)
  end
end
