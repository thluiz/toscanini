defmodule Toscanini.PrivateSite do
  @moduledoc """
  URL das páginas do Vox privado: `<base>/privado/<guid>/<ano>/<mês>/W<semana>/<slug>/`.

  O guid é a credencial do site (quem tem o link entra), então ele vem da variável de ambiente
  `TOSCANINI_VOX_PRIVATE_GUID` e nunca fica no código nem no git. Sem ele não há link. A notificação do
  Telegram é particular, por isso pode levar o link.
  """

  @doc "O guid configurado, ou `nil` se a variável faltar ou estiver vazia."
  def guid do
    case System.get_env("TOSCANINI_VOX_PRIVATE_GUID") do
      g when is_binary(g) and g != "" -> g
      _ -> nil
    end
  end

  @doc "URL do episódio no site privado, ou `nil` sem path ou sem guid."
  def url(vox_path, base_url, guid \\ guid())
  def url(nil, _base_url, _guid), do: nil
  def url(_vox_path, _base_url, guid) when guid in [nil, ""], do: nil

  def url(vox_path, base_url, guid) do
    page = vox_path |> String.replace_suffix(".md", "") |> String.trim("/")
    "#{String.trim_trailing(base_url, "/")}/privado/#{guid}/#{page}/"
  end
end
