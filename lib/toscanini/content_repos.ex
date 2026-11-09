defmodule Toscanini.ContentRepos do
  @moduledoc """
  Os dois repositórios de conteúdo: o público (`vox-content`, publicado no Vox) e o
  privado (`vox-private-content`, material que nunca vai para o site público).

  Os dois têm o mesmo layout (`YYYY/MM/Wnn/<slug>.md` + `.json`), então as ferramentas
  que localizam um episódio só precisam saber em qual raiz procurar. A raiz privada é
  opcional: sem `TOSCANINI_VOX_PRIVATE_DIR` só existe o repositório público.
  """

  @doc "Raízes onde procurar episódios: `[{dir, private?}]`, a pública primeiro."
  def dirs do
    case System.get_env("TOSCANINI_VOX_PRIVATE_DIR") do
      dir when is_binary(dir) and dir != "" ->
        [{System.fetch_env!("TOSCANINI_VOX_CONTENT_DIR"), false}, {dir, true}]

      _ ->
        [{System.fetch_env!("TOSCANINI_VOX_CONTENT_DIR"), false}]
    end
  end

  @doc """
  Tira o prefixo `privado/<token>/` de um path/URL do site privado
  (`privado/<token>/2026/11/W45/slug` vira `2026/11/W45/slug`).
  """
  def normalize_path(path) do
    path
    |> String.replace(~r{^/?privado/[^/]+/}, "")
    |> String.trim_trailing("/")
  end

  @doc """
  Acha o `.json` de um episódio. Tenta o path exato (formato canônico) e, se não
  existir, a busca por slug sem diferenciar maiúsculas, em cada raiz de `dirs`.
  Devolve `{:ok, json_path, private?}` ou `:error`.
  """
  def locate_json(path, slug, dirs \\ nil) do
    path = normalize_path(path)

    Enum.find_value(dirs || dirs(), :error, fn {dir, private?} ->
      case find_in(dir, path, slug) do
        nil -> nil
        json_path -> {:ok, json_path, private?}
      end
    end)
  end

  defp find_in(dir, path, slug) do
    direct = Path.join(dir, Path.rootname(path) <> ".json")

    if File.exists?(direct) do
      direct
    else
      target = String.downcase(slug)

      dir
      |> Path.join("**/*.json")
      |> Path.wildcard()
      |> Enum.find(fn p -> String.downcase(Path.basename(p, ".json")) == target end)
    end
  end
end
