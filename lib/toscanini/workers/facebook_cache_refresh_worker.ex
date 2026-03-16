defmodule Toscanini.Workers.FacebookCacheRefreshWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}
  alias Toscanini.Clients.Facebook

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    pipeline    = Repo.get!(Pipeline, pid)
    write_files = Pipeline.get_results(pipeline)["write_files"] || %{}
    vox_path    = write_files["vox_path"]

    result =
      if vox_path do
        base_url = Application.get_env(:toscanini, :vox_base_url, "https://vox.thluiz.com")
        url = "#{base_url}/#{String.replace_suffix(vox_path, ".md", "")}"
        case Facebook.refresh_cache(url) do
          :ok                       -> %{"refreshed" => true, "url" => url}
          {:error, :not_configured} -> %{"refreshed" => false, "reason" => "not_configured"}
          {:error, reason}          -> %{"refreshed" => false, "reason" => inspect(reason)}
        end
      else
        %{"refreshed" => false, "reason" => "no_vox_path"}
      end

    Pipeline.save_result(pipeline, "facebook_cache_refresh", result)
    Dispatcher.advance(pid)
    :ok
  end
end
