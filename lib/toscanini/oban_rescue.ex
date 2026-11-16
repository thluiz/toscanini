defmodule Toscanini.ObanRescue do
  @moduledoc """
  No boot, devolve à fila os jobs que ficaram em `executing`.

  O Toscanini é um nó só, com o Oban no motor Lite (SQLite) e sem o plugin
  `Lifeline`. Quando o serviço para no meio de um job (restart, crash, BSOD), o job
  fica `executing` para sempre e o pipeline dele trava. Como não existe outro nó,
  todo job `executing` encontrado antes de o Oban subir é órfão por definição.

  O `Lifeline` não serve aqui: ele resgata por idade (`rescue_after`), e uma
  transcrição passa de uma hora, então ele ou resgataria job vivo ou demoraria horas.

  A tentativa interrompida é devolvida (`attempt - 1`): um restart não é falha do job,
  e vários restarts seguidos não podem esgotar o `max_attempts` e descartar o
  episódio. O trabalho em si recomeça do zero (o whisper morre junto com o serviço,
  `KillMode=control-group`).

  Roda como filho da árvore de supervisão entre o `Repo` e o `Oban`: executa de forma
  síncrona no `start_link/0` e devolve `:ignore`.
  """

  require Logger
  import Ecto.Query

  alias Toscanini.Repo

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary, type: :worker}
  end

  def start_link do
    rescue_orphans()
    :ignore
  end

  @doc "Move todo job `executing` para `available`, devolvendo a tentativa. Retorna os ids."
  def rescue_orphans do
    orphans =
      Repo.all(
        from j in Oban.Job,
          where: j.state == "executing",
          select: %{id: j.id, worker: j.worker, queue: j.queue, args: j.args, attempt: j.attempt}
      )

    if orphans != [] do
      ids = Enum.map(orphans, & &1.id)

      Repo.update_all(
        from(j in Oban.Job, where: j.id in ^ids and j.state == "executing"),
        set: [state: "available", scheduled_at: DateTime.utc_now()],
        inc: [attempt: -1]
      )

      for o <- orphans do
        Logger.warning(
          "[ObanRescue] job #{o.id} (#{o.queue}, #{o.worker}, #{inspect(o.args)}) estava executing no boot; " <>
            "volta para available, tentativa #{o.attempt} devolvida"
        )
      end
    end

    Enum.map(orphans, & &1.id)
  end
end

