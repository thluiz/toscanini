defmodule Toscanini.Clients.Facebook do
  @graph_api_url "https://graph.facebook.com/"

  def refresh_cache(url) do
    token = Application.get_env(:toscanini, :facebook_app_token, "")
    if token == "" do
      {:error, :not_configured}
    else
      Req.post(@graph_api_url, params: [id: url, scrape: true, access_token: token])
      |> case do
        {:ok, %{status: 200}} -> :ok
        {:ok, resp}           -> {:error, resp.status}
        {:error, reason}      -> {:error, reason}
      end
    end
  end
end
