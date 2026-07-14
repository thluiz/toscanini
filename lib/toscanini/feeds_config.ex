defmodule Toscanini.FeedsConfig do
  @moduledoc """
  Config dos feeds editável em runtime (sem redeploy), persistida em
  `data/feeds_config.json` — espelha o padrão do scheduler.

    * `safety_hour_utc` — hora UTC (0–23) em que o check diário roda fora da janela
      quente. Default 6 (06:00 UTC = 03:00 BRT), cedo pra já ter episódios
      processando de manhã.
    * `hot_grace_min` — folga (min) no limiar da janela quente: o check é devido
      quando `elapsed >= hot_interval_min - hot_grace_min`. Default 10. Sem folga,
      o check gravado alguns segundos após a hora cheia fazia o sweep seguinte ver
      59min < 60 e pular — resultando em check a cada 2h em vez de 1h.
  """
  @default %{"safety_hour_utc" => 6, "hot_grace_min" => 10}

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

  @doc "Folga (min) no limiar da janela quente."
  def hot_grace_min, do: read()["hot_grace_min"]

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

  # Valida só as chaves conhecidas presentes; ignora desconhecidas.
  defp validate(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case validate_field(k, v) do
        :ignore         -> {:cont, {:ok, acc}}
        {:ok, key, val} -> {:cont, {:ok, Map.put(acc, key, val)}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  defp validate_field("safety_hour_utc", v) when is_integer(v) and v >= 0 and v <= 23,
    do: {:ok, "safety_hour_utc", v}

  defp validate_field("safety_hour_utc", _),
    do: {:error, "safety_hour_utc must be an integer 0-23"}

  defp validate_field("hot_grace_min", v) when is_integer(v) and v >= 0 and v <= 59,
    do: {:ok, "hot_grace_min", v}

  defp validate_field("hot_grace_min", _),
    do: {:error, "hot_grace_min must be an integer 0-59"}

  defp validate_field(_, _), do: :ignore
end
