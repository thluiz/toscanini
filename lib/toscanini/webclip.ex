defmodule Toscanini.Webclip do
  @moduledoc """
  Pure decisions of the `scholion_webclip` flow (POST /publish/webclip), kept
  apart from the workers so they can be tested without HTTP.

  A pipeline that the server alone cannot finish is **parked**
  (`status: "parked"`), never failed: it waits for a machine with the
  author's logged-in browser (Claude Code + Claude in Chrome) to list it,
  capture the page text and resume it. Park reasons:

    * `"browser"`           — the headless fetch can't reach the content
      (blocked domain, consent wall, thin content, fetch failing every attempt).
      Resume with the page `text`.
    * `"audit_red"`         — ghost-audit said red; the service refuses the save
      for this principal. Resume (optionally with `related_notes`/`text`) to
      recompose, or dismiss.
    * `"audit_unavailable"` — the audit never ran, every attempt. Resume once the
      audit is back.
    * `"slug_conflict"`     — a note with that slug already exists in the vault.
  """

  @park_for_browser ~w[blocked_domain consent_wall_unresolved thin_content]
  @retry_then_browser ~w[fetch_timeout fetch_failed]
  @retry_then_fail ~w[rate_limited summary_failed internal_error]

  @doc """
  Classifies a `compose` outcome.

  `last_attempt?` tells whether Oban has attempts left: a transient error
  retries while it can, and only then parks (or fails).

  Returns `:ok` (operation good to save), `:retry`, `{:park, reason, detail}`
  or `{:fail, message}`.
  """
  def classify_compose({:ok, op}, last_attempt?) do
    audit = op["audit"] || %{}

    cond do
      audit_unavailable?(audit) and last_attempt? ->
        {:park, "audit_unavailable", %{"message" => audit["summary"]}}

      audit_unavailable?(audit) ->
        :retry

      audit["verdict"] == "red" ->
        {:park, "audit_red",
         %{"findings" => audit["findings"] || [], "message" => audit["summary"]}}

      true ->
        :ok
    end
  end

  def classify_compose({:api_error, %{"code" => code} = error}, last_attempt?) do
    detail = %{"code" => code, "message" => error["message"]}

    cond do
      code in @park_for_browser ->
        {:park, "browser", detail}

      code in @retry_then_browser and last_attempt? ->
        {:park, "browser", detail}

      code in @retry_then_browser ->
        :retry

      code in @retry_then_fail and last_attempt? ->
        {:fail, "webclipper #{code}: #{error["message"]}"}

      code in @retry_then_fail ->
        :retry

      true ->
        {:fail, "webclipper #{code}: #{error["message"]}"}
    end
  end

  def classify_compose({:api_error, error}, _last), do: {:fail, "webclipper: #{inspect(error)}"}

  def classify_compose({:error, reason}, true), do: {:fail, "webclipper unreachable: #{reason}"}
  def classify_compose({:error, _reason}, false), do: :retry

  @doc """
  Classifies a `save` outcome: `:ok`, `:retry`, `{:park, reason, detail}` or
  `{:fail, message}`. An expired operation can't be saved anymore, so it goes
  back to compose (`:recompose`).
  """
  def classify_save({:ok, _saved}, _last), do: :ok

  def classify_save({:api_error, %{"code" => "slug_conflict"} = e}, _last),
    do: {:park, "slug_conflict", %{"code" => "slug_conflict", "message" => e["message"]}}

  def classify_save({:api_error, %{"code" => "audit_red"} = e}, _last),
    do: {:park, "audit_red", %{"code" => "audit_red", "message" => e["message"]}}

  def classify_save({:api_error, %{"code" => "operation_not_found"}}, _last), do: :recompose

  def classify_save({:api_error, %{"code" => "operation_already_saved"}}, _last), do: :ok

  def classify_save({:api_error, %{"code" => code} = e}, last) do
    if e["retryable"] == true and not last,
      do: :retry,
      else: {:fail, "webclipper save #{code}: #{e["message"]}"}
  end

  def classify_save({:error, _reason}, false), do: :retry

  def classify_save({:error, reason}, true),
    do: {:fail, "webclipper unreachable on save: #{reason}"}

  defp audit_unavailable?(audit) do
    String.starts_with?(to_string(audit["summary"]), "ghost-audit unavailable")
  end

  @doc """
  Body of the `compose` call. URL mode by default; text mode when the
  pipeline was resumed with page text captured in the browser.
  """
  def compose_body(input, resume \\ nil) do
    resume = resume || %{}
    url = input["url"]

    base =
      case resume["text"] do
        text when is_binary(text) and text != "" ->
          %{
            "text" => text,
            "title" => blank_to(resume["title"], url),
            "url" => url,
            "domain" => domain_slug(url)
          }

        _ ->
          %{"url" => url}
      end

    case resume["related_notes"] do
      [_ | _] = notes -> Map.put(base, "relatedNotes", notes)
      _ -> base
    end
  end

  @doc ~S"""
  Domain as the webclipper's text mode expects it: host without `www.`,
  dots turned into hyphens (`www.nytimes.com` → `nytimes-com`).
  """
  def domain_slug(url) do
    host = URI.parse(to_string(url)).host || ""

    host
    |> String.downcase()
    |> String.replace_prefix("www.", "")
    |> String.replace(".", "-")
  end

  @doc "Normalizes the `quotes` field of the request into a list of non-empty strings."
  def normalize_quotes(nil), do: []
  def normalize_quotes(q) when is_binary(q), do: normalize_quotes([q])

  def normalize_quotes(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def normalize_quotes(_), do: []

  defp blank_to(v, fallback) when is_binary(v),
    do: if(String.trim(v) == "", do: fallback, else: v)

  defp blank_to(_, fallback), do: fallback
end
