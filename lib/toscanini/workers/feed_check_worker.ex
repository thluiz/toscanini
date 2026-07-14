defmodule Toscanini.Workers.FeedCheckWorker do
  @moduledoc """
  Checa UMA assinatura por episódios novos (via `Feeds.check/1`). Enfileirado
  pelo `FeedSweepWorker` ou por `POST /subscriptions/:id/check`.
  """
  use Oban.Worker, queue: :feeds, max_attempts: 3

  require Logger
  alias Toscanini.Feeds

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => id}}) do
    case Feeds.get_subscription(id) do
      nil ->
        Logger.warning("[FeedCheck] assinatura #{id} não encontrada — ignorando")
        :ok

      sub ->
        case Feeds.check(sub) do
          {:ok, _}         -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
