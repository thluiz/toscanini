defmodule Toscanini.TranscribeFeeder do
  @moduledoc """
  Portão da fila de transcrição: decide qual job entra no próximo slot livre do whisper.

  Sem o portão a fila `:transcribe` era FIFO puro. Um lote é serial (um item em voo),
  e cada item novo entrava no fim da fila, atrás de todos os avulsos que os feeds
  despejam de hora em hora: o lote avançava um episódio por drenagem completa da
  fila (um lote de 199 episódios levaria meses).

  Agora o `Dispatcher` insere o job de transcribe no portão (estado `scheduled`,
  `scheduled_at` em `gate_at/0`, que o Stager do Oban nunca alcança) com a lane
  dele em `meta.lane`: `"general"` para avulsos, o `batch_id` para item de lote.
  Quando um slot abre, `run/1` escolhe a lane servida há mais tempo entre as que
  têm candidato pronto e libera o candidato mais antigo dela (FIFO dentro da lane).
  Lane sem candidato não entra na conta: sem disputa, quem tem trabalho leva todos
  os slots. Job marcado `meta.prioritized` (`POST /pipelines/:id/prioritize`) sai
  antes de qualquer lane.

  "Último despacho" de uma lane sai de `MAX(COALESCE(attempted_at, scheduled_at))`
  dos jobs já liberados: nenhum estado novo, sobrevive a restart. Lane nunca
  servida conta como a mais antiga, então um lote recém-criado pega a próxima vaga.

  Slots livres = limite da janela atual (`Scheduler`) menos jobs `executing` e
  `available` (liberados, à espera do Oban). O Oban continua impondo a
  concorrência real; o portão só manda na ordem. `run/1` pode correr em paralelo
  (telemetria, cron, dispatcher) e no pior caso libera um job a mais, o que só
  adianta a ordem de um FIFO que o Oban respeita de qualquer forma.

  No boot (`start_link/0`, antes do Oban) todo job `available` da fila volta ao
  portão (`adopt/0`): os que ficaram da versão anterior e os que o `ObanRescue`
  devolveu, para que após um restart a ordem respeite as lanes.
  """

  require Logger
  import Ecto.Query

  alias Toscanini.{Repo, Pipeline, Scheduler}

  @queue "transcribe"
  @general "general"
  @gate_at ~U[2999-01-01 00:00:00.000000Z]
  @default_limit 2

  def general_lane, do: @general
  def gate_at, do: @gate_at

  # -- Supervisão (boot) ------------------------------------------------------

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary, type: :worker}
  end

  @doc false
  def start_link do
    unless Keyword.get(Application.get_env(:toscanini, Oban, []), :testing) == :manual do
      adopt()
      run()
    end

    :ignore
  end

  @doc "Handler de telemetria: fim de job da fila transcribe abre slot, roda o feeder."
  def attach do
    :telemetry.attach_many(
      "toscanini-transcribe-feeder",
      [[:oban, :job, :stop], [:oban, :job, :exception]],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(_event, _measurements, %{job: %{queue: @queue}}, _config) do
    # Fora do processo do job: exceção aqui desligaria o handler.
    Task.start(fn -> run() end)
    :ok
  end

  def handle_event(_, _, _, _), do: :ok

  # -- Entrada no portão -------------------------------------------------------

  @doc "Lane de um pipeline pelos params: `batch_id` do lote, ou `general`."
  def lane_for(%Pipeline{} = p), do: lane_for(Pipeline.get_params(p))
  def lane_for(params) when is_map(params), do: params["batch_id"] || @general

  @doc "Opções de `Oban.Job.new/2` que deixam um job de transcribe no portão, na lane dada."
  def gate_opts(lane), do: [scheduled_at: @gate_at, meta: %{"lane" => lane}]

  @doc """
  Boot: devolve ao portão todo job `available` da fila transcribe, preenchendo
  `meta.lane` a partir do pipeline quando falta (jobs da versão sem portão). Retorna os ids.
  """
  def adopt do
    gate_jobs(from j in Oban.Job, where: j.queue == @queue and j.state == "available")
  end

  @doc """
  Jobs que voltaram à fila por fora do portão e vão re-entrar pela lane: `retryable`
  (falha com tentativa sobrando, inclusive o whisper morto num restart) e `available`
  já tentado (`attempted_at` preenchido: snooze do cooldown da GPU, ou retry que o
  Stager já liberou). Um job que o feeder acabou de liberar nunca foi tentado, então
  não é tocado. Sem isto um retry entrava na fila na frente das lanes.
  """
  def regate do
    gate_jobs(
      from j in Oban.Job,
        where:
          j.queue == @queue and
            (j.state == "retryable" or (j.state == "available" and not is_nil(j.attempted_at)))
    )
  end

  defp gate_jobs(query) do
    rows = Repo.all(from j in query, select: {j.id, j.state, j.args, j.meta})

    for {id, state, args, meta} <- rows do
      meta = meta || %{}
      lane = meta["lane"] || lane_from_pipeline(args["pipeline_id"])

      Repo.update_all(
        from(j in Oban.Job, where: j.id == ^id and j.state == ^state),
        set: [state: "scheduled", scheduled_at: @gate_at, meta: Map.put(meta, "lane", lane)]
      )

      id
    end
  end

  defp lane_from_pipeline(nil), do: @general

  defp lane_from_pipeline(pipeline_id) do
    case Repo.get(Pipeline, pipeline_id) do
      nil -> @general
      p -> lane_for(p)
    end
  end

  # -- Liberação ---------------------------------------------------------------

  @doc "Libera jobs do portão até preencher os slots livres. Retorna os ids liberados."
  def run(limit \\ current_limit()) do
    regate()
    free = limit - busy_count()

    if free <= 0 do
      []
    else
      ids = pick(gated(), last_served(), free)

      if ids != [] do
        Repo.update_all(
          from(j in Oban.Job, where: j.id in ^ids and j.state == "scheduled"),
          set: [state: "available", scheduled_at: DateTime.utc_now()]
        )

        Logger.info(
          "[TranscribeFeeder] liberou #{length(ids)} job(s) (#{free} slot(s) livre(s)): #{inspect(ids)}"
        )
      end

      ids
    end
  end

  @doc """
  Seleção pura. `candidates` em ordem FIFO, cada um `%{id, lane, prioritized}`;
  `served` mapeia lane -> último despacho (unix segundos, ou nil = nunca);
  `free` é o número de slots. Prioritários saem primeiro, ignorando lanes; depois,
  a cada vaga, a lane servida há mais tempo (empate: nome da lane) cede o seu
  candidato mais antigo.
  """
  def pick(_candidates, _served, free) when free <= 0, do: []

  def pick(candidates, served, free) do
    {prioritized, rest} = Enum.split_with(candidates, & &1.prioritized)
    first = prioritized |> Enum.take(free) |> Enum.map(& &1.id)
    first ++ pick_lanes(rest, served, free - length(first), [])
  end

  defp pick_lanes([], _served, _free, acc), do: Enum.reverse(acc)
  defp pick_lanes(_candidates, _served, free, acc) when free <= 0, do: Enum.reverse(acc)

  defp pick_lanes(candidates, served, free, acc) do
    lane =
      candidates
      |> Enum.map(& &1.lane)
      |> Enum.uniq()
      |> Enum.min_by(fn l -> {Map.get(served, l) || -1, l} end)

    next = Enum.find(candidates, &(&1.lane == lane))

    # :infinity > qualquer inteiro: a lane acabou de ser servida.
    pick_lanes(
      List.delete(candidates, next),
      Map.put(served, lane, :infinity),
      free - 1,
      [next.id | acc]
    )
  end

  @doc "Limite de slots agora: janela do `Scheduler`, senão o limite da fila na config."
  def current_limit do
    case Scheduler.current_window(:transcribe) do
      %{"limit" => limit} when is_integer(limit) -> limit
      _ -> configured_limit()
    end
  end

  defp configured_limit do
    case Application.get_env(:toscanini, Oban, [])[:queues] do
      queues when is_list(queues) -> Keyword.get(queues, :transcribe, @default_limit)
      _ -> @default_limit
    end
  end

  # -- Leituras ----------------------------------------------------------------

  @doc "Jobs que já têm slot: executando ou liberados à espera do Oban."
  def busy_count do
    Repo.one(
      from j in Oban.Job,
        where: j.queue == @queue and j.state in ["available", "executing"],
        select: count(j.id)
    )
  end

  @doc "Candidatos no portão, em ordem FIFO (prioridade, depois id)."
  def gated do
    Repo.all(
      from j in Oban.Job,
        where: j.queue == @queue and j.state == "scheduled" and j.scheduled_at >= ^@gate_at,
        order_by: [asc: j.priority, asc: j.id],
        select: %{
          id: j.id,
          pipeline_id: fragment("json_extract(?, '$.pipeline_id')", j.args),
          meta: j.meta
        }
    )
    |> Enum.map(&with_lane/1)
  end

  @doc "Jobs liberados e ainda não iniciados, na ordem em que o Oban os vai pegar."
  def released do
    Repo.all(
      from j in Oban.Job,
        where: j.queue == @queue and j.state == "available",
        order_by: [asc: j.priority, asc: j.scheduled_at, asc: j.id],
        select: %{
          id: j.id,
          pipeline_id: fragment("json_extract(?, '$.pipeline_id')", j.args),
          meta: j.meta
        }
    )
    |> Enum.map(&with_lane/1)
  end

  defp with_lane(%{meta: meta} = row) do
    meta = meta || %{}

    row
    |> Map.put(:lane, meta["lane"] || @general)
    |> Map.put(:prioritized, meta["prioritized"] == true)
    |> Map.delete(:meta)
  end

  @doc "Último despacho por lane (unix segundos), a partir dos jobs já liberados."
  def last_served do
    Repo.all(
      from j in Oban.Job,
        where: j.queue == @queue and j.scheduled_at < ^@gate_at,
        group_by: fragment("coalesce(json_extract(?, '$.lane'), 'general')", j.meta),
        select:
          {fragment("coalesce(json_extract(?, '$.lane'), 'general')", j.meta),
           max(fragment("coalesce(?, ?)", j.attempted_at, j.scheduled_at))}
    )
    |> Map.new(fn {lane, ts} -> {lane, to_unix(ts)} end)
  end

  @doc "Jobs executando por lane."
  def executing_by_lane do
    Repo.all(
      from j in Oban.Job,
        where: j.queue == @queue and j.state == "executing",
        group_by: fragment("coalesce(json_extract(?, '$.lane'), 'general')", j.meta),
        select: {fragment("coalesce(json_extract(?, '$.lane'), 'general')", j.meta), count(j.id)}
    )
    |> Map.new()
  end

  @doc """
  A fila como o portão a vê: liberados primeiro (ordem do Oban), depois os do
  portão na ordem em que seriam liberados se houvesse slot para todos.
  """
  def waiting do
    released = released() |> Enum.map(&Map.put(&1, :state, "released"))
    gated = gated()
    order = pick(gated, last_served(), length(gated))
    by_id = Map.new(gated, &{&1.id, &1})

    released ++ Enum.map(order, &Map.put(by_id[&1], :state, "gated"))
  end

  defp to_unix(nil), do: nil
  defp to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp to_unix(%NaiveDateTime{} = dt), do: dt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

  defp to_unix(bin) when is_binary(bin) do
    case NaiveDateTime.from_iso8601(bin) do
      {:ok, dt} -> to_unix(dt)
      _ -> nil
    end
  end
end
