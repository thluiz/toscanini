defmodule Toscanini.Workers.FeedSweepWorker do
  @moduledoc """
  Disparado de hora em hora pelo `Oban.Plugins.Cron`. Varre as assinaturas
  ativas, filtra as que estão "devidas" (`Feeds.due?/2`) e enfileira um
  `FeedCheckWorker` por assinatura — isolando falha/retry por feed.
  """
  use Oban.Worker, queue: :feeds, max_attempts: 1

  require Logger
  alias Toscanini.Feeds
  alias Toscanini.Workers.FeedCheckWorker

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    due =
      Feeds.list_active()
      |> Enum.filter(&Feeds.due?(&1, now))

    Enum.each(due, fn sub ->
      %{"subscription_id" => sub.id}
      |> FeedCheckWorker.new()
      |> Oban.insert!()
    end)

    Logger.info("[FeedSweep] #{length(due)} assinatura(s) devida(s) enfileirada(s)")
    :ok
  end
end
