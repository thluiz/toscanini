defmodule Toscanini.Scheduler do
  @moduledoc """
  Janelas de agendamento por fila (`data/queue_schedules.json`).

  Cada janela é `%{"from" => h, "to" => h, "limit" => n, "gpu" => bool, "cores" => n}`
  (hora local, `from` inclusivo, `to` exclusivo) e pode trazer `"days"`, uma lista
  de dias (`"mon".."sun"`) em que ela vale. Janela sem `"days"` vale todos os dias.
  A primeira janela que casa com a hora e o dia ganha, então janelas específicas
  (ex.: fim de semana) vão antes das gerais.

  `priv/whisper_worker.py` repete essa regra em Python (`select_model/0`).
  """

  @days ~w(mon tue wed thu fri sat sun)

  def days, do: @days

  @doc "Primeira janela de `windows` que cobre `now` (hora e dia da semana), ou `nil`."
  def window_for(windows, %NaiveDateTime{} = now) when is_list(windows) do
    day = Enum.at(@days, Date.day_of_week(NaiveDateTime.to_date(now)) - 1)
    Enum.find(windows, &(in_hours?(&1, now.hour) and on_day?(&1, day)))
  end

  def window_for(_windows, _now), do: nil

  @doc "Janela da fila `queue` agora (hora local), lida de `queue_schedules.json`."
  def current_window(queue, now \\ NaiveDateTime.local_now()) do
    with {:ok, raw} <- File.read(config_path()),
         {:ok, schedules} <- Jason.decode(raw) do
      window_for(schedules[to_string(queue)], now)
    else
      _ -> nil
    end
  end

  @doc "Valida a lista de janelas recebida pela API."
  def validate_windows(windows) when is_list(windows) do
    if Enum.all?(windows, &valid_window?/1),
      do: :ok,
      else: {:error, "invalid windows format"}
  end

  def validate_windows(_), do: {:error, "windows must be an array"}

  defp valid_window?(w) when is_map(w) do
    is_integer(w["from"]) and is_integer(w["to"]) and
      is_integer(w["limit"]) and w["limit"] >= 0 and valid_days?(Map.get(w, "days"))
  end

  defp valid_window?(_), do: false

  defp valid_days?(nil), do: true
  defp valid_days?(days) when is_list(days), do: days != [] and Enum.all?(days, &(&1 in @days))
  defp valid_days?(_), do: false

  defp in_hours?(%{"from" => from, "to" => to}, hour), do: hour >= from and hour < to
  defp in_hours?(_, _), do: false

  defp on_day?(%{"days" => days}, day) when is_list(days), do: day in days
  defp on_day?(_, _), do: true

  defp config_path,
    do: Path.join(Application.get_env(:toscanini, :data_dir, "data"), "queue_schedules.json")
end
