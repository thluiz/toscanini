defmodule Toscanini.AudioDuration do
  @moduledoc """
  Duration of the collected audio file, measured with `ffprobe`.

  Feed metadata cannot be trusted for duration. The PocketCasts API returns
  `duration: 202740` for Filosofia Pop #224, whose MP3 lasts 3379s ("56:19"
  read as h:m upstream). That number made `TranscriptCheck` reject a complete
  transcript as truncated, made `valid_transcript?` demand 60x the characters,
  and would have been published as a 56h episode.

  Two roles, two references:

    * **Download check** (`compare/2`): the feed duration is the reference. Audio
      much shorter than the feed may be an incomplete download; much longer may
      be the wrong file. Either fails the pipeline with `mismatch_message/2`
      (prefix "duração divergente"), to be reviewed and resubmitted with
      `accept_duration_mismatch: true` when the audio is fine.
    * **Transcript check**: the measured audio is the reference, since that is
      what Whisper transcribed (`reconcile/2`).

  Tolerance comes from a scan of 1134 collected episodes (2026-11-20): dynamic
  ad insertion makes audio up to ~1.7x the feed, and mono files 2x (feed
  computed as stereo). The only case with audio shorter than the feed was #224.
  """

  require Logger

  # Divergence above this fraction is logged so bad feeds become visible.
  @divergence 0.10
  # Download check: audio / feed outside [min, max] fails the pipeline.
  @min_ratio 0.9
  @max_ratio 3.0
  @timeout_ms 30_000

  @doc "Measures `path` with ffprobe. Returns `{:ok, secs}` (integer) or `:error`."
  @spec probe(String.t() | nil) :: {:ok, non_neg_integer()} | :error
  def probe(nil), do: :error

  def probe(path) do
    with true <- File.regular?(path),
         exe when is_binary(exe) <- System.find_executable("ffprobe") do
      task =
        Task.async(fn ->
          System.cmd(exe, ["-v", "error", "-show_entries", "format=duration",
                           "-of", "default=noprint_wrappers=1:nokey=1", path],
                     stderr_to_stdout: true)
        end)

      case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {out, 0}} -> parse(out)
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  @doc false
  def parse(out) do
    case out |> String.trim() |> Float.parse() do
      {secs, _} when secs > 0 -> {:ok, round(secs)}
      _ -> :error
    end
  end

  @doc """
  Picks the duration to use: measured when available, otherwise the metadata
  value (or 0). Pure, so it is tested without ffprobe.
  """
  @spec reconcile(number() | nil, {:ok, non_neg_integer()} | :error) :: non_neg_integer()
  def reconcile(_meta, {:ok, measured}), do: measured
  def reconcile(meta, :error) when is_number(meta), do: trunc(meta)
  def reconcile(_meta, :error), do: 0

  @doc "True when metadata and measurement disagree by more than #{round(@divergence * 100)}%."
  @spec divergent?(number() | nil, non_neg_integer()) :: boolean()
  def divergent?(meta, measured) when is_number(meta) and meta > 0 and measured > 0,
    do: abs(meta - measured) / measured > @divergence

  def divergent?(_meta, _measured), do: false

  @doc """
  Download check: `:ok`, or `{:mismatch, ratio}` when audio / feed is outside
  [#{@min_ratio}, #{@max_ratio}]. Without a feed value or a measurement there is
  nothing to compare, so `:ok`.
  """
  @spec compare(number() | nil, {:ok, non_neg_integer()} | :error) :: :ok | {:mismatch, float()}
  def compare(meta, {:ok, audio}) when is_number(meta) and meta > 0 and audio > 0 do
    ratio = audio / meta
    if ratio < @min_ratio or ratio > @max_ratio, do: {:mismatch, ratio}, else: :ok
  end

  def compare(_meta, _measured), do: :ok

  @doc "Failure message for a download-check mismatch."
  def mismatch_message(meta, {:ok, audio}) do
    "duração divergente: áudio #{audio}s, feed #{trunc(meta)}s (#{round(audio / meta * 100)}%). " <>
      "Se o áudio estiver completo, reenviar com accept_duration_mismatch: true"
  end

  @doc """
  Measures `path` and returns the duration to use, logging when the metadata
  value diverges. `label` identifies the episode in the log.
  """
  @spec effective(number() | nil, String.t() | nil, String.t()) :: non_neg_integer()
  def effective(meta, path, label \\ "") do
    measured = probe(path)

    case measured do
      {:ok, secs} ->
        if divergent?(meta, secs) do
          Logger.info("[AudioDuration] #{label}: metadata says #{meta}s, audio is #{secs}s; using audio")
        end

      :error ->
        Logger.warning("[AudioDuration] #{label}: ffprobe failed on #{inspect(path)}; using metadata #{inspect(meta)}")
    end

    reconcile(meta, measured)
  end
end

