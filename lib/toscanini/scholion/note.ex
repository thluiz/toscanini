defmodule Toscanini.Scholion.Note do
  @moduledoc """
  Serializa os campos estruturados de uma nota de citação (vindos do preset
  quote-note do vox-intelligence) no markdown Scholion: frontmatter YAML + corpo.

  Determinístico — aspas corretas por campo (title/sources em aspas duplas,
  summary/date em aspas simples) e o `---` de fechamento SEMPRE presente. É aqui
  que mora o "como publicar"; o vox-intelligence só compõe o conteúdo.
  """

  @doc """
  `fields` é o mapa (chaves string) com slug/title/summary/tags/has_commentary/
  sources/body/authorship. `date` é ISO 8601 com offset. `opts[:draft]` (bool)
  insere `draft: true` no frontmatter.
  """
  def to_markdown(fields, date, opts \\ []) do
    draft? = Keyword.get(opts, :draft, false)

    tags = fields["tags"] || []
    sources = fields["sources"] || []

    lines =
      [
        "---",
        "title: " <> dq(fields["title"] || ""),
        "date: " <> sq(date),
        "category: quote",
        "summary: " <> sq(fields["summary"] || ""),
        "tags: [" <> Enum.map_join(tags, ", ", &dq/1) <> "]",
        "has_commentary: " <> if(fields["has_commentary"] == true, do: "true", else: "false")
      ] ++
        if(draft?, do: ["draft: true"], else: []) ++
        ["sources:"] ++
        Enum.flat_map(sources, &source_lines/1) ++
        ["---"]

    Enum.join(lines, "\n") <> "\n\n" <> String.trim(to_string(fields["body"] || "")) <> "\n"
  end

  defp source_lines(s) do
    (["  - title: " <> dq(s["title"] || "")]
     |> add_str(s["author"], "    author: ")
     |> add_int(s["year"], "    year: ")
     |> add_str(s["publisher"], "    publisher: ")
     |> add_str(s["url"], "    url: ")) ++
      ["    kind: " <> to_string(s["kind"] || "other")]
  end

  defp add_str(lines, v, prefix) when is_binary(v) do
    case String.trim(v) do
      "" -> lines
      t -> lines ++ [prefix <> dq(t)]
    end
  end

  defp add_str(lines, _v, _prefix), do: lines

  defp add_int(lines, v, prefix) when is_integer(v), do: lines ++ [prefix <> Integer.to_string(v)]

  defp add_int(lines, v, prefix) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> lines ++ [prefix <> Integer.to_string(n)]
      :error -> lines
    end
  end

  defp add_int(lines, _v, _prefix), do: lines

  # YAML double-quoted scalar
  defp dq(s) do
    esc = s |> to_string() |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"" <> esc <> "\""
  end

  # YAML single-quoted scalar
  defp sq(s) do
    esc = s |> to_string() |> String.replace("'", "''")
    "'" <> esc <> "'"
  end
end
