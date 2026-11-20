defmodule Toscanini.TranscribeFeederTest do
  use Toscanini.DataCase, async: false

  alias Toscanini.{TranscribeFeeder, Repo, Pipeline}
  alias Toscanini.Pipeline.Dispatcher

  @gate TranscribeFeeder.gate_at()
  @t10 ~U[2026-01-01 10:00:00.000000Z]
  @t11 ~U[2026-01-01 11:00:00.000000Z]
  @t12 ~U[2026-01-01 12:00:00.000000Z]

  defp c(id, lane, prioritized \\ false), do: %{id: id, lane: lane, prioritized: prioritized}

  describe "pick/3 (seleção pura)" do
    test "sem slots livres não libera nada" do
      assert TranscribeFeeder.pick([c(1, "general")], %{}, 0) == []
      assert TranscribeFeeder.pick([], %{}, 3) == []
    end

    test "só a geral com candidatos: leva todos os slots, em ordem FIFO" do
      cands = [c(1, "general"), c(2, "general"), c(3, "general")]
      assert TranscribeFeeder.pick(cands, %{"general" => 100}, 2) == [1, 2]
    end

    test "lote nunca servido ganha da geral já servida" do
      cands = [c(1, "general"), c(2, "general"), c(3, "b1")]
      assert TranscribeFeeder.pick(cands, %{"general" => 100}, 1) == [3]
    end

    test "geral parada há mais tempo ganha do lote servido há pouco" do
      cands = [c(1, "general"), c(3, "b1")]
      assert TranscribeFeeder.pick(cands, %{"general" => 100, "b1" => 200}, 1) == [1]
    end

    test "cada vaga vai à lane servida há mais tempo; dentro da lane, FIFO" do
      cands = [c(1, "general"), c(2, "general"), c(3, "general"), c(4, "b1"), c(5, "b1"), c(6, "b2")]
      served = %{"general" => 300, "b1" => 100, "b2" => 200}
      # b1 (100), b2 (200), general (300); depois todas empatam e o nome desempata.
      assert TranscribeFeeder.pick(cands, served, 6) == [4, 6, 1, 5, 2, 3]
    end

    test "lane sem candidato não entra na conta: sem disputa, quem tem trabalho leva tudo" do
      # b1 foi servido há mais tempo, mas não tem candidato pronto.
      cands = [c(1, "general"), c(2, "general")]
      assert TranscribeFeeder.pick(cands, %{"general" => 500, "b1" => 1}, 2) == [1, 2]
    end

    test "prioritário sai antes de qualquer lane" do
      cands = [c(1, "general"), c(2, "b1"), c(3, "general", true)]
      assert TranscribeFeeder.pick(cands, %{"general" => 100}, 2) == [3, 2]
    end
  end

  # -- helpers de banco --------------------------------------------------------

  defp pipeline!(params \\ %{}, step \\ "collect") do
    Repo.insert!(%Pipeline{
      id: Ecto.UUID.generate(),
      content_type: "podcast",
      collector: "pocketcasts",
      status: "running",
      current_step: step,
      params: Jason.encode!(params),
      results: Jason.encode!(%{"collect" => %{"title" => params["title"] || "t"}})
    })
  end

  defp job!(pipeline_id, state, lane, fields \\ []) do
    meta = if lane, do: %{"lane" => lane}, else: %{}

    job =
      %{"pipeline_id" => pipeline_id}
      |> Oban.Job.new(worker: "Toscanini.Workers.TranscribeWorker", queue: "transcribe", meta: meta)
      |> Repo.insert!()

    job
    |> Ecto.Changeset.change([state: state] ++ fields)
    |> Repo.update!()
  end

  defp gated!(lane, pipeline_id \\ pipeline!().id),
    do: job!(pipeline_id, "scheduled", lane, scheduled_at: @gate)

  defp executing!(lane, at), do: job!(pipeline!().id, "executing", lane, attempted_at: at, scheduled_at: at)
  defp completed!(lane, at), do: job!(pipeline!().id, "completed", lane, attempted_at: at, scheduled_at: at)
  defp available!(lane, at), do: job!(pipeline!().id, "available", lane, scheduled_at: at)

  defp reload(job), do: Repo.get!(Oban.Job, job.id)
  defp gated?(job), do: job.state == "scheduled" and DateTime.compare(job.scheduled_at, @gate) == :eq

  describe "run/1 (banco)" do
    test "libera o lote nunca servido antes da geral, e só até preencher os slots" do
      executing!("general", @t10)
      g1 = gated!("general")
      _g2 = gated!("general")
      b1 = gated!("b1")

      assert TranscribeFeeder.run(2) == [b1.id]

      b1 = reload(b1)
      assert b1.state == "available"
      assert DateTime.compare(b1.scheduled_at, @gate) == :lt
      assert gated?(reload(g1))

      # 1 executing + 1 liberado = 2 slots ocupados
      assert TranscribeFeeder.run(2) == []
    end

    test "job já liberado conta como slot ocupado" do
      available!("general", @t12)
      _g = gated!("general")
      assert TranscribeFeeder.run(1) == []
    end

    test "último despacho vem dos jobs já rodados; a lane mais parada ganha" do
      completed!("general", @t12)
      completed!("b1", @t11)
      g = gated!("general")
      b = gated!("b1")

      assert TranscribeFeeder.last_served() == %{
               "general" => DateTime.to_unix(@t12),
               "b1" => DateTime.to_unix(@t11)
             }

      assert TranscribeFeeder.run(1) == [b.id]
      # b1 acabou de ser servido (scheduled_at = agora): a próxima vaga é da geral.
      assert TranscribeFeeder.run(2) == [g.id]
    end

    test "prioritário sai primeiro mesmo com lote nunca servido" do
      completed!("general", @t12)
      p = pipeline!()
      g = job!(p.id, "scheduled", nil, scheduled_at: @gate, meta: %{"lane" => "general", "prioritized" => true})
      _b = gated!("b1")

      assert TranscribeFeeder.run(1) == [g.id]
    end

    test "job no portão sem meta.lane cai na geral" do
      j = job!(pipeline!().id, "scheduled", nil, scheduled_at: @gate)
      assert [%{id: id, lane: "general", prioritized: false}] = TranscribeFeeder.gated()
      assert id == j.id
    end

    test "waiting/0: liberados primeiro, depois o portão na ordem prevista" do
      completed!("general", @t12)
      a = available!("general", @t12)
      g1 = gated!("general")
      g2 = gated!("general")
      b = gated!("b1")

      assert Enum.map(TranscribeFeeder.waiting(), &{&1.id, &1.state}) == [
               {a.id, "released"},
               {b.id, "gated"},
               {g1.id, "gated"},
               {g2.id, "gated"}
             ]
    end
  end

  describe "adopt/0" do
    test "devolve available ao portão com a lane tirada do pipeline" do
      lote = pipeline!(%{"batch_id" => "B", "batch_item_id" => 1})
      avulso = pipeline!()
      jb = job!(lote.id, "available", nil)
      ja = job!(avulso.id, "available", nil)
      ex = executing!("general", @t10)

      assert Enum.sort(TranscribeFeeder.adopt()) == Enum.sort([jb.id, ja.id])

      jb = reload(jb)
      assert gated?(jb)
      assert jb.meta["lane"] == "B"

      ja = reload(ja)
      assert gated?(ja)
      assert ja.meta["lane"] == "general"

      assert reload(ex).state == "executing"
    end

    test "preserva meta.lane já preenchida" do
      j = available!("b9", @t12)
      TranscribeFeeder.adopt()
      assert reload(j).meta["lane"] == "b9"
    end
  end

  describe "Dispatcher" do
    test "transcribe entra no portão com a lane do lote" do
      # Ocupa todos os slots possíveis para o feeder não liberar na hora.
      for _ <- 1..3, do: executing!("general", @t10)
      p = pipeline!(%{"batch_id" => "B", "batch_item_id" => 1}, "collect")

      assert :ok = Dispatcher.advance(p.id)

      [job] = Repo.all(from j in Oban.Job, where: j.queue == "transcribe" and j.state == "scheduled")
      assert job.worker == "Toscanini.Workers.TranscribeWorker"
      assert job.args == %{"pipeline_id" => p.id}
      assert gated?(job)
      assert job.meta["lane"] == "B"
    end

    test "avulso vai para a lane general" do
      for _ <- 1..3, do: executing!("general", @t10)
      p = pipeline!(%{"url" => "https://x"}, "collect")
      Dispatcher.advance(p.id)

      [job] = Repo.all(from j in Oban.Job, where: j.queue == "transcribe" and j.state == "scheduled")
      assert job.meta["lane"] == "general"
    end

    test "com slot livre o job novo é liberado na hora" do
      p = pipeline!(%{}, "collect")
      Dispatcher.advance(p.id)

      [job] = Repo.all(from j in Oban.Job, where: j.queue == "transcribe")
      assert job.state == "available"
      assert job.meta["lane"] == "general"
    end

    test "os demais steps continuam entrando direto na fila" do
      p = pipeline!(%{}, "transcribe")
      Dispatcher.advance(p.id)

      [job] = Repo.all(from j in Oban.Job, where: j.queue == "default")
      assert job.worker == "Toscanini.Workers.SummarizeWorker"
      assert job.state == "available"
      assert job.meta == %{}
    end
  end
end
