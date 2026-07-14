defmodule Toscanini.Workers.RetentionSweepWorker do
  @moduledoc """
  Varredura diária de retenção: apaga o áudio LOCAL de episódios já arquivados no
  cold storage há mais de `retention_days`, liberando disco no `collected`.

  Disparado pelo `Oban.Plugins.Cron`. Auto-gated e conservador:

  1. No-op se `Archive.enabled?/0` for `false`.
  2. No-op se `TOSCANINI_ARCHIVE_BACKLOG_DONE != true` — trava operacional: nunca
     limpa antes de todo o histórico estar confirmado no cold (invariante do plano).
  3. Em `dry_run` (default `true`), só loga os candidatos — não apaga.
  4. **Nunca apaga sem confirmar o par no S3** (`Archive.object_exists?/1`).

  Candidato = pipeline `done` com `results.s3_archive.done = true` e `archived_at`
  mais velho que `retention_days`. Apaga o áudio local (`collect.mp3`/`collect.audio`);
  a transcrição do youtube e o mp3 do podcast já estão no cold.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger
  alias Toscanini.{Repo, Pipeline, Archive}
  alias Toscanini.Clients.GossipGate

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cfg = Archive.config()

    cond do
      not Archive.enabled?() ->
        Logger.info("[Retention] skip — arquivamento desligado")
        :ok

      cfg[:backlog_done] != true ->
        Logger.info("[Retention] skip — backlog ainda não confirmado (TOSCANINI_ARCHIVE_BACKLOG_DONE)")
        :ok

      true ->
        sweep(cfg)
    end
  end

  defp sweep(cfg) do
    days   = cfg[:retention_days] || 30
    dry    = cfg[:dry_run] != false
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.to_iso8601()

    Logger.info("[Retention] início (retention_days=#{days}, dry_run=#{dry}, cutoff=#{cutoff})")

    candidates = fetch_candidates(cutoff)
    {deleted, freed, kept} = Enum.reduce(candidates, {0, 0, 0}, &process(&1, &2, dry))

    msg =
      "[Retention] fim — #{if dry, do: "DRY-RUN ", else: ""}candidatos=#{length(candidates)} " <>
        "apagados=#{deleted} liberado=#{Float.round(freed / 1_073_741_824, 2)}GB não-confirmados=#{kept}"

    Logger.info(msg)
    if not dry and deleted > 0, do: GossipGate.send("🧹 " <> msg)
    :ok
  end

  # {id, results_json} de pipelines done, arquivados e vencidos.
  defp fetch_candidates(cutoff) do
    sql = """
    SELECT id, results FROM pipelines
    WHERE status = 'done'
      AND json_valid(results)
      AND json_extract(results, '$.s3_archive.done') = 1
      AND json_extract(results, '$.s3_archive.archived_at') <= ?
    """

    case Repo.query(sql, [cutoff]) do
      {:ok, %{rows: rows}} -> rows
      _ -> []
    end
  end

  defp process([id, results_json], {del, freed, kept}, dry) do
    results = Jason.decode!(results_json)
    collect = results["collect"] || %{}
    arch    = results["s3_archive"] || %{}

    audio = collect["mp3"] || collect["audio"]
    key   = arch["s3_key"]

    cond do
      is_nil(audio) or not File.exists?(audio) ->
        # Já limpo (sweep anterior) ou nunca teve local — nada a fazer.
        {del, freed, kept}

      is_nil(key) or not Archive.object_exists?(key) ->
        Logger.warning("[Retention] #{id}: mantém local — objeto S3 não confirmado (#{key})")
        {del, freed, kept + 1}

      dry ->
        size = file_size(audio)
        Logger.info("[Retention] #{id}: WOULD delete #{audio} (#{mb(size)}MB), s3=#{key}")
        {del, freed, kept}

      true ->
        size = file_size(audio)

        case File.rm(audio) do
          :ok ->
            Logger.info("[Retention] #{id}: apagou #{audio} (#{mb(size)}MB), s3=#{key}")
            {del + 1, freed + size, kept}

          {:error, reason} ->
            Logger.error("[Retention] #{id}: falha ao apagar #{audio}: #{inspect(reason)}")
            {del, freed, kept}
        end
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: s}} -> s
      _ -> 0
    end
  end

  defp mb(bytes), do: div(bytes, 1_048_576)
end
