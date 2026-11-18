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
    * `"audit_red"`         — ghost-audit said red; the service refuses to
      publish it for this principal. Since 0.2.50 the note is first saved as
      an unpublished draft (`draft: true`, results `webclip_draft`), so nothing
      is lost while it waits. Resume (optionally with `related_notes`/`text`)
      to recompose onto the draft's slug, or dismiss (the draft stays).
    * `"audit_unavailable"` — the audit never ran, every attempt. Resume once the
      audit is back.
    * `"slug_conflict"`     — a note with that slug already exists in the vault.
    * `"response_mismatch"` — compose answered with a clipping for another URL
      on every attempt (concurrent calls got each other's responses on
      2026-11-16). Nothing is saved; resume to compose again.
    * `"save_failed"`       — compose went fine but save failed transiently on
      every attempt (timeout, 502). Resume retries the save of the same
      operation while it lives (24h); expired, it recomposes.
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
  def classify_compose(outcome, last_attempt?, expected_url)

  def classify_compose({:ok, op} = outcome, last_attempt?, expected_url)
      when is_binary(expected_url) do
    got = get_in(op, ["clipping", "url"])

    cond do
      same_url?(got, expected_url) ->
        classify_compose(outcome, last_attempt?)

      last_attempt? ->
        {:park, "response_mismatch",
         %{
           "code" => "response_mismatch",
           "message" => "compose answered for #{inspect(got)}, expected #{expected_url}"
         }}

      true ->
        :retry
    end
  end

  def classify_compose(outcome, last_attempt?, _expected_url),
    do: classify_compose(outcome, last_attempt?)

  @doc """
  Whether the clipping URL in a compose response is the URL that was sent,
  ignoring scheme, a leading `www.`, a trailing slash and host case. The
  webclipper echoes the request URL, so anything else is a response that
  belongs to another request. A missing URL never matches.
  """
  def same_url?(got, expected) when is_binary(got) and is_binary(expected),
    do: url_key(got) == url_key(expected)

  def same_url?(_got, _expected), do: false

  defp url_key(url) do
    uri = URI.parse(String.trim(url))
    host = (uri.host || "") |> String.downcase() |> String.replace_prefix("www.", "")
    path = (uri.path || "") |> String.trim_trailing("/")
    {host, path, uri.query}
  end

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

  A transient failure (timeout, 502, retryable error) on the last attempt
  parks with `"save_failed"` instead of failing: the composed operation lives
  24h in the webclipper, so resuming retries the save of that same operation
  without paying for a new compose (see `resume_step/2`).
  """
  def classify_save({:ok, _saved}, _last), do: :ok

  def classify_save({:api_error, %{"code" => "slug_conflict"} = e}, _last),
    do: {:park, "slug_conflict", %{"code" => "slug_conflict", "message" => e["message"]}}

  def classify_save({:api_error, %{"code" => "audit_red"} = e}, _last),
    do: {:park, "audit_red", %{"code" => "audit_red", "message" => e["message"]}}

  def classify_save({:api_error, %{"code" => "operation_not_found"}}, _last), do: :recompose

  def classify_save({:api_error, %{"code" => "operation_already_saved"}}, _last), do: :ok

  def classify_save({:api_error, %{"code" => code} = e}, last) do
    cond do
      e["retryable"] == true and not last ->
        :retry

      e["retryable"] == true ->
        {:park, "save_failed", %{"code" => code, "message" => e["message"]}}

      true ->
        {:fail, "webclipper save #{code}: #{e["message"]}"}
    end
  end

  def classify_save({:error, _reason}, false), do: :retry

  def classify_save({:error, reason}, true),
    do: {:park, "save_failed", %{"code" => "unreachable", "message" => to_string(reason)}}

  @doc """
  Step a webclip resumes at, from the pipeline's `status`, `current_step`,
  `results` and the resume params. A pipeline that stopped at save (parked
  `"save_failed"`, or failed at `webclip_save` before 0.2.53) with a known
  operation and no new page text or related notes retries the save of that
  operation: if it expired, the save answers `operation_not_found` and the
  flow recomposes by itself. Anything else needs a fresh operation, so it
  resumes at compose.
  """
  def resume_step(status, current_step, results, resume) do
    op_id = get_in(results, ["webclip_compose", "operation_id"])

    stopped_at_save? =
      case status do
        "parked" -> get_in(results, ["parked", "reason"]) == "save_failed"
        "failed" -> current_step == "webclip_save"
        _ -> false
      end

    if is_binary(op_id) and op_id != "" and stopped_at_save? and map_size(resume || %{}) == 0,
      do: "webclip_save",
      else: "webclip_compose"
  end

  defp audit_unavailable?(audit) do
    String.starts_with?(to_string(audit["summary"]), "ghost-audit unavailable")
  end

  @doc """
  Recompose onto the draft's path: when a red note was saved as a draft,
  the next compose asks for the same slug, so the save that follows
  replaces the draft instead of leaving a second note next to it.
  """
  def with_draft_slug(body, %{"slug" => slug}) when is_binary(slug) and slug != "",
    do: Map.put(body, "slug", slug)

  def with_draft_slug(body, _draft), do: body

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
