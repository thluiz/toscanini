defmodule Toscanini.Workers.TranscribeFeedWorker do
  @moduledoc """
  Rede de segurança do `TranscribeFeeder`: roda a cada minuto pelo cron do Oban.
  O gatilho principal é a telemetria de fim de job; o cron cobre a mudança de
  janela (limite 2 -> 3 às 21h abre um slot sem nenhum job terminar) e qualquer
  evento perdido.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    Toscanini.TranscribeFeeder.run()
    :ok
  end
end
