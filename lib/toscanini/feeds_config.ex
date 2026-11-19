defmodule Toscanini.FeedsConfig do
  @moduledoc """
  Config dos feeds editável em runtime (sem redeploy), persistida em
  `data/feeds_config.json` — espelha o padrão do scheduler.

    * `safety_hours_utc` — horas UTC (0–23) da rede de segurança, que checa as
      assinaturas fora da janela quente. Default `[3, 15]`: duas checagens a cada
      12h, a das 03:00 UTC (00:00 BRT) com tempo de processar tudo antes do dia
      começar. A chave antiga `safety_hour_utc` (uma hora só) ainda é aceita e
      vira `[h]`.
    * `hot_grace_min` — folga (min) no limiar da janela quente: o check é devido
      quando `elapsed >= hot_interval_min - hot_grace_min`. Default 10. Sem folga,
      o check gravado alguns segundos após a hora cheia fazia o sweep seguinte ver
      59min < 60 e pular — resultando em check a cada 2h em vez de 1h.
  """
  @default %{"safety_hours_utc" => [3, 15], "hot_grace_min" => 10}

  defp path, do: Path.join(Application.get_env(:toscanini, :data_dir, "data"), "feeds_config.json")

  @doc "Config atual (default mesclado com o que estiver no arquivo)."
  def read do
    with {:ok, raw} <- File.read(path()),
         {:ok, data} when is_map(data) <- Jason.decode(raw) do
      Map.merge(@default, upgrade(data))
    else
      _ -> @default
    end
  end

  # Arquivo gravado antes da v0.2.56: `safety_hour_utc` (inteiro) → `safety_hours_utc` ([h]).
  defp upgrade(%{"safety_hour_utc" => h} = data) do
    data
    |> Map.delete("safety_hour_utc")
    |> Map.put_new("safety_hours_utc", [h])
  end

  defp upgrade(data), do: data

  @doc "Horas UTC (0–23, ordenadas) da rede de segurança."
  def safety_hours_utc, do: read()["safety_hours_utc"]

  @doc """
  Gap mínimo (h) desde o último check para a rede de segurança disparar: metade do
  menor intervalo entre âncoras consecutivas (`[3, 15]` → 6h; uma âncora só → 12h).
  Evita rechecar uma assinatura vista há pouco (ex.: no fim de um dia quente).
  """
  def safety_min_gap_hours(hours \\ safety_hours_utc()) do
    sorted = Enum.sort(hours)
    wrap = hd(sorted) + 24 - List.last(sorted)

    sorted
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> b - a end)
    |> Enum.concat([wrap])
    |> Enum.min()
    |> div(2)
  end

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

  defp validate_field("safety_hours_utc", [_ | _] = hs) do
    if Enum.all?(hs, &hour?/1),
      do: {:ok, "safety_hours_utc", hs |> Enum.uniq() |> Enum.sort()},
      else: {:error, "safety_hours_utc must be a non-empty list of integers 0-23"}
  end

  defp validate_field("safety_hours_utc", _),
    do: {:error, "safety_hours_utc must be a non-empty list of integers 0-23"}

  # Chave antiga (uma hora só): vira safety_hours_utc = [h].
  defp validate_field("safety_hour_utc", v) do
    if hour?(v),
      do: {:ok, "safety_hours_utc", [v]},
      else: {:error, "safety_hour_utc must be an integer 0-23"}
  end

  defp validate_field("hot_grace_min", v) when is_integer(v) and v >= 0 and v <= 59,
    do: {:ok, "hot_grace_min", v}

  defp validate_field("hot_grace_min", _),
    do: {:error, "hot_grace_min must be an integer 0-59"}

  defp validate_field(_, _), do: :ignore

  defp hour?(v), do: is_integer(v) and v >= 0 and v <= 23
end
