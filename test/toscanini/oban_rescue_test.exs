defmodule Toscanini.ObanRescueTest do
  use Toscanini.DataCase, async: false

  alias Toscanini.{ObanRescue, Repo}

  defp job(state, attempt, args \\ %{"pipeline_id" => "p"}) do
    %{"pipeline_id" => "x"}
    |> Map.merge(args)
    |> Oban.Job.new(worker: "Toscanini.Workers.TranscribeWorker", queue: "transcribe", max_attempts: 3)
    |> Repo.insert!()
    |> Ecto.Changeset.change(state: state, attempt: attempt)
    |> Repo.update!()
  end

  test "executing vira available e devolve a tentativa" do
    j = job("executing", 1)
    assert ObanRescue.rescue_orphans() == [j.id]

    j = Repo.get!(Oban.Job, j.id)
    assert j.state == "available"
    assert j.attempt == 0
  end

  test "vários restarts seguidos não esgotam o max_attempts" do
    j = job("executing", 1)

    for _ <- 1..5 do
      ObanRescue.rescue_orphans()
      # o Oban pega o job de novo: attempt sobe e ele volta a executing
      Repo.get!(Oban.Job, j.id) |> Ecto.Changeset.change(state: "executing", attempt: 1) |> Repo.update!()
    end

    ObanRescue.rescue_orphans()
    j = Repo.get!(Oban.Job, j.id)
    assert j.state == "available"
    assert j.attempt == 0
    assert j.attempt < j.max_attempts
  end

  test "não mexe em job de outro estado" do
    a = job("available", 0)
    c = job("completed", 1)
    r = job("retryable", 2)
    assert ObanRescue.rescue_orphans() == []

    assert Repo.get!(Oban.Job, a.id).state == "available"
    assert Repo.get!(Oban.Job, c.id).state == "completed"
    assert %{state: "retryable", attempt: 2} = Repo.get!(Oban.Job, r.id)
  end

  test "sem órfãos, não faz nada" do
    assert ObanRescue.rescue_orphans() == []
  end
end

