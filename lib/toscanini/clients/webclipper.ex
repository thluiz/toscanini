defmodule Toscanini.Clients.Webclipper do
  @moduledoc """
  Client for the scholion-webclipper API (`/api/webclip/` behind the local
  nginx). The webclipper is a plain service: fetch + extract + compose +
  ghost-audit + save. Every flow decision (retry, park for the browser,
  quotes, notify) lives in the Toscanini pipeline, not there.

  Authenticates as the `toscanini` principal (role `write`): it can compose
  and save, never force a save past a red ghost-audit verdict.
  """

  # compose makes up to three sequential upstream calls; nginx allows 300s.
  @compose_timeout 330_000
  @save_timeout 120_000

  defp base_url, do: Application.fetch_env!(:toscanini, :base_url)
  defp api_key, do: Application.get_env(:toscanini, :webclipper_api_key, "")

  defp headers, do: [{"x-api-key", api_key()}]

  @doc """
  `POST /webclip/compose`. `body` is either `%{"url" => url}` (URL mode) or
  `%{"text" => ..., "title" => ..., "url" => ..., "domain" => ...}` (text
  mode), optionally with `"relatedNotes"`.

  Returns `{:ok, operation}` on 201, `{:api_error, error_map}` when the
  service answered with its structured error, `{:error, reason}` on
  transport failure.
  """
  def compose(body) when is_map(body) do
    Req.post("#{base_url()}/api/webclip/webclip/compose",
      json: body,
      headers: headers(),
      receive_timeout: @compose_timeout,
      retry: false
    )
    |> handle()
  end

  @doc "`POST /webclip/{id}/save` in `commit` mode: the service writes, commits and pushes its own clone."
  def save(operation_id) when is_binary(operation_id) do
    Req.post("#{base_url()}/api/webclip/webclip/#{operation_id}/save",
      json: %{"mode" => "commit"},
      headers: headers(),
      receive_timeout: @save_timeout,
      retry: false
    )
    |> handle()
  end

  defp handle({:ok, %{status: s, body: body}}) when s in 200..299 and is_map(body),
    do: {:ok, body}

  defp handle({:ok, %{body: %{"error" => %{} = error}}}), do: {:api_error, error}
  defp handle({:ok, %{status: s, body: b}}), do: {:error, "webclipper HTTP #{s}: #{inspect(b)}"}
  defp handle({:error, e}), do: {:error, inspect(e)}
end
