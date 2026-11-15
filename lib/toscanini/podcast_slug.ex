defmodule Toscanini.PodcastSlug do
  @moduledoc """
  Slug do podcast para a página `/podcasts/<slug>/` do Vox.

  O renderer grava `podcast_slug:` no frontmatter de cada episódio e o Hugo
  usa esse campo como taxonomia: cada slug vira uma PASTA em `public/` no
  build, que roda no Windows. Por isso o slug não pode depender do nome bruto
  do podcast — `Scott & Mark Learn To...` (ponto final) e `Nul` (nome
  reservado) quebravam o build com "The system cannot find the path".

  Garantias (cobertas em `podcast_slug_test.exs`):

    * só `[a-z0-9-]`, sem hífen nas pontas nem hífens duplos;
    * nunca vazio — nome sem nenhuma letra latina vira `podcast-<hash>`;
    * nunca nome reservado do Windows (CON, PRN, AUX, NUL, COM0-9, LPT0-9);
    * no máximo 80 caracteres, cortado em fronteira de palavra;
    * determinístico: o mesmo nome dá sempre o mesmo slug, então grafias
      que só diferem em pontuação/caixa/acento caem na mesma página
      (`Lenny's Podcast` / `Lennys Podcast`).
  """

  @max_len 80

  @reserved MapSet.new(
              ~w(con prn aux nul) ++
                Enum.map(0..9, &"com#{&1}") ++
                Enum.map(0..9, &"lpt#{&1}")
            )

  @spec slug(String.t() | nil) :: String.t() | nil
  def slug(nil), do: nil

  def slug(name) when is_binary(name) do
    name
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed |> base() |> ensure_non_empty(trimmed) |> ensure_not_reserved()
    end
  end

  defp base(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{M}/u, "")
    |> String.downcase()
    # apóstrofo não separa palavra: "Lenny's" → "lennys", não "lenny-s"
    |> String.replace(~r/['’`´]/u, "")
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> truncate()
  end

  defp truncate(s) when byte_size(s) <= @max_len, do: s

  defp truncate(s) do
    cut = binary_part(s, 0, @max_len)

    case :binary.matches(cut, "-") do
      [] -> cut
      matches -> binary_part(cut, 0, matches |> List.last() |> elem(0))
    end
    |> String.trim("-")
  end

  defp ensure_non_empty("", original) do
    hash = :crypto.hash(:sha256, original) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    "podcast-" <> hash
  end

  defp ensure_non_empty(s, _original), do: s

  defp ensure_not_reserved(s) do
    if MapSet.member?(@reserved, s), do: s <> "-podcast", else: s
  end
end
