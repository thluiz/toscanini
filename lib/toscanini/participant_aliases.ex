defmodule Toscanini.ParticipantAliases do
  @moduledoc """
  Normaliza a grafia de participantes a partir da tabela mantida no
  vox-content (`_meta/participants-aliases.csv`, colunas `variant,canonical`).

  O summarize transcreve nomes de ouvido, então a mesma pessoa aparece com
  grafias diferentes ("Thomas Trauman" / "Thomas Traumann"). Aplicado no
  `EnrichTagsWorker`, antes das tags de participante serem derivadas: troca
  `participants` pela grafia canônica e o slug da variante em `tags` pelo slug
  canônico, sem duplicar.

  A tabela é relida a cada chamada (poucas centenas de linhas) — edição no
  vox-content vale a partir do próximo episódio, sem restart.
  """

  @rel_path "_meta/participants-aliases.csv"

  @doc "Caminho da tabela dentro do clone do vox-content."
  def path(vox_content_dir), do: Path.join(vox_content_dir, @rel_path)

  @doc "Lê a tabela. Arquivo ausente → mapa vazio (normalização vira no-op)."
  def load(path) do
    case File.read(path) do
      {:ok, body} -> parse(body)
      {:error, _} -> %{}
    end
  end

  @doc false
  def parse(body) do
    body
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^("(?:[^"]|"")*"|[^,]*),("(?:[^"]|"")*"|[^,]*)$/, line) do
        [_, v, c] -> [{unquote_field(v), unquote_field(c)}]
        _ -> []
      end
    end)
    |> Enum.reject(fn {v, c} -> v == "" or c == "" or v == c end)
    |> Map.new()
  end

  defp unquote_field("\"" <> _ = f),
    do: f |> String.slice(1..-2//1) |> String.replace(~s(""), ~s(")) |> String.trim()

  defp unquote_field(f), do: String.trim(f)

  @doc """
  Aplica a tabela em `participants` e `tags` do JSON do episódio.
  Retorna `{json_atualizado, [%{"from" => v, "to" => c}]}`.
  """
  def normalize(json_data, aliases) when map_size(aliases) == 0, do: {json_data, []}

  def normalize(json_data, aliases) do
    participants = json_data["participants"] || []
    tags = json_data["tags"] || []

    renamed =
      participants
      |> Enum.filter(&Map.has_key?(aliases, &1))
      |> Enum.uniq()
      |> Enum.map(&%{"from" => &1, "to" => aliases[&1]})

    tag_map =
      for {v, c} <- aliases, slug(v) != slug(c), into: %{}, do: {slug(v), slug(c)}

    updated =
      json_data
      |> Map.put("participants", participants |> Enum.map(&Map.get(aliases, &1, &1)) |> Enum.uniq())
      |> Map.put("tags", tags |> Enum.map(&Map.get(tag_map, &1, &1)) |> Enum.uniq())

    {updated, renamed}
  end

  @doc """
  Slug de tag: sem acento, minúsculo, pontuação (inclusive hífen) removida,
  espaço → hífen. "Kasten-Smith" → "kastensmith".
  """
  def slug(nil), do: ""

  def slug(str) do
    str
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{M}/u, "")
    |> String.replace(~r/[^a-z0-9\s]+/u, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
  end
end
