defmodule Toscanini.Workers.VerifyUrlWorker do
  use Oban.Worker, queue: :default, max_attempts: 2

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}

  @max_retries 40
  @retry_delay_ms 30_000

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    pipeline    = Repo.get!(Pipeline, pid)
    write_files = Pipeline.get_results(pipeline)["write_files"] || %{}
    vox_path    = write_files["vox_path"]

    if vox_path do
      base_url = Application.get_env(:toscanini, :vox_base_url, "https://vox.thluiz.com")
      url = "#{base_url}/#{String.replace_suffix(vox_path, ".md", "")}"

      case wait_for_url(url, @max_retries) do
        {:ok, attempts} ->
          Pipeline.save_result(pipeline, "verify_url", %{"url" => url, "ok" => true, "attempts" => attempts})
          Dispatcher.advance(pid)
          :ok

        {:error, reason} ->
          {:error, "verify_url failed for #{url}: #{reason}"}
      end
    else
      Pipeline.save_result(pipeline, "verify_url", %{"ok" => true, "skipped" => true})
      Dispatcher.advance(pid)
      :ok
    end
  end

  defp wait_for_url(url, max_retries) do
    do_wait(url, max_retries, 1)
  end

  defp do_wait(_url, 0, attempt) do
    {:error, "not accessible after #{attempt - 1} attempts"}
  end

  defp do_wait(url, retries_left, attempt) do
    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: 200}} ->
        {:ok, attempt}

      {:ok, %{status: status}} ->
        if retries_left > 1 do
          Process.sleep(@retry_delay_ms)
          do_wait(url, retries_left - 1, attempt + 1)
        else
          {:error, "HTTP #{status} after #{attempt} attempts"}
        end

      {:error, reason} ->
        if retries_left > 1 do
          Process.sleep(@retry_delay_ms)
          do_wait(url, retries_left - 1, attempt + 1)
        else
          {:error, "request error after #{attempt} attempts: #{inspect(reason)}"}
        end
    end
  end
end
