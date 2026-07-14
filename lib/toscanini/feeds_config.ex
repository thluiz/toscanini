defmodule Toscanini.FeedsConfig do
  @moduledoc """
  Config dos feeds editável em runtime (sem redeploy), persistida em
  `data/feeds_config.json` — espelha o padrão do scheduler. Hoje só a hora-âncora
  UTC da rede de segurança diária.

    * `safety_hour_utc` — hora UTC (0–23) em que o check diário roda fora da janela
      quente. Default 6 (06:00 UTC = 03:00 BRT), cedo pra já ter episódios
      processando de manhã.
  """
  @default %{"safety_hour_utc" => 6}

  defp path, do: Path.join(Application.get_env(:toscanini, :data_dir, "data"), "feeds_config.json")

  @doc "Config atual (default mesclado com o que estiver no arquivo)."
  def read do
    with {:ok, raw} <- File.read(path()),
         {:ok, data} when is_map(data) <- Jason.decode(raw) do
      Map.merge(@default, data)
    else
      _ -> @default
    end
  end

  @doc "Hora UTC (0–23) da rede de segurança diária."
  def safety_hour_utc, do: read()["safety_hour_utc"]

  @doc """
  Atualiza campos da config (só chaves conhecidas) e persiste. Devolve
  `{:ok, config}` ou `{:error, reason}`.
  """
  def put(attrs) when is_map(attrs) do
    with {:ok, clean} <- validate(attrs) do
      merged = Map.merge(read(), clean)
      File.mkdir_p!(Path.dirname(path()))
      File.write!(path(), Jason.encode!(merged, pretty: true))
      {:ok, merged}
    end
  end

  defp validate(attrs) do
    case Map.fetch(attrs, "safety_hour_utc") do
      :error ->
        {:ok, %{}}

      {:ok, h} when is_integer(h) and h >= 0 and h <= 23 ->
        {:ok, %{"safety_hour_utc" => h}}

      {:ok, _} ->
        {:error, "safety_hour_utc must be an integer 0-23"}
    end
  end
end
