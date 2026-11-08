defmodule ToscaniniWeb.SchedulerController do
  use ToscaniniWeb, :controller

  alias Toscanini.Scheduler

  @config_path Path.join(Application.get_env(:toscanini, :data_dir, "data"), "queue_schedules.json")

  defp config_path, do: @config_path

  @default_window %{"from" => 0, "to" => 24, "limit" => 1, "gpu" => false, "cores" => 14}

  defp read_config do
    with {:ok, raw} <- File.read(config_path()),
         {:ok, data} <- Jason.decode(raw) do
      {:ok, data}
    else
      _ -> {:ok, %{"transcribe" => [@default_window]}}
    end
  end

  defp current_limit(windows) do
    case Scheduler.window_for(windows, NaiveDateTime.local_now()) do
      %{"limit" => limit} -> limit
      nil -> nil
    end
  end

  def show(conn, %{"queue" => queue}) do
    case read_config() do
      {:ok, config} ->
        case Map.get(config, queue) do
          nil -> conn |> put_status(404) |> json(%{error: "queue not found: #{queue}"})
          windows -> json(conn, %{queue: queue, windows: windows})
        end
      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: reason})
    end
  end

  def update(conn, %{"queue" => queue, "windows" => windows}) do
    with {:ok, config} <- read_config(),
         :ok <- validate_windows(windows) do
      updated = Map.put(config, queue, windows)
      json_str = Jason.encode!(updated, pretty: true)
      File.write!(config_path(), json_str)

      # Apply current window limit immediately
      case current_limit(windows) do
        nil -> :ok
        limit ->
          queue_atom = String.to_existing_atom(queue)
          Oban.scale_queue(queue: queue_atom, limit: limit)
      end

      json(conn, %{ok: true, queue: queue, windows: windows})
    else
      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: reason})
    end
  end

  defp validate_windows(windows), do: Scheduler.validate_windows(windows)
end
