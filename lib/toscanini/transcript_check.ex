defmodule Toscanini.TranscriptCheck do
  @moduledoc """
  Detecta transcrições degeneradas do Whisper antes de seguirem no pipeline.

  - **loop**: uma mesma linha é ≥ 50% das linhas (ex.: "Добро пожаловать на наш
    канал!" a cada 30s quando o idioma forçado está errado, ou o jingle do
    podcast repetido até o fim).
  - **truncada**: o último timestamp cobre < 50% da duração.

  Limiares calibrados no acervo do vox-content (5379 transcrições, 2026-10-31):
  pegaram os 7 episódios quebrados, sem falso positivo. Transcrições com uma
  palavra por linha têm a palavra mais comum em ~4% das linhas, longe do limiar.
  """

  @min_lines 10
  @max_top_share 0.5
  @min_duration 300
  @min_coverage 0.5

  @timestamp ~r/^\[(\d+):(\d+):(\d+)\]/

  @spec check(String.t(), number() | nil) :: :ok | {:error, String.t()}
  def check(transcript, duration_secs) do
    raw = transcript |> String.split("\n") |> Enum.reject(&(String.trim(&1) == ""))

    with :ok <- check_loop(raw) do
      check_coverage(raw, duration_secs)
    end
  end

  defp check_loop(raw) when length(raw) < @min_lines, do: :ok

  defp check_loop(raw) do
    {top, count} =
      raw
      |> Enum.map(&(Regex.replace(@timestamp, &1, "") |> String.trim()))
      |> Enum.frequencies()
      |> Enum.max_by(fn {_line, n} -> n end)

    share = count / length(raw)

    if share >= @max_top_share do
      {:error,
       "transcrição em loop: #{count}/#{length(raw)} linhas iguais (#{pct(share)}): #{inspect(String.slice(top, 0, 80))}"}
    else
      :ok
    end
  end

  defp check_coverage(raw, duration) when is_number(duration) and duration >= @min_duration do
    last =
      raw
      |> Enum.reverse()
      |> Enum.find_value(fn line ->
        case Regex.run(@timestamp, line, capture: :all_but_first) do
          [h, m, s] -> String.to_integer(h) * 3600 + String.to_integer(m) * 60 + String.to_integer(s)
          nil -> nil
        end
      end)

    coverage = if last, do: last / duration, else: nil

    if coverage && coverage < @min_coverage do
      {:error, "transcrição truncada: termina em #{last}s de #{duration}s (#{pct(coverage)})"}
    else
      :ok
    end
  end

  defp check_coverage(_raw, _duration), do: :ok

  defp pct(x), do: "#{round(x * 100)}%"
end
