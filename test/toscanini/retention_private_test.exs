defmodule Toscanini.RetentionPrivateTest do
  use ExUnit.Case, async: true

  alias Toscanini.Workers.RetentionSweepWorker

  @moduletag :tmp_dir

  defp sidecar(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    path
  end

  test "sidecar com metadata.private == true é privado", %{tmp_dir: dir} do
    jf =
      sidecar(
        dir,
        "a.json",
        Jason.encode!(%{"metadata" => %{"private" => true, "source" => "local"}})
      )

    assert RetentionSweepWorker.private?(jf)
  end

  test "sem a marca, com false, ou com valor que não seja true, não é privado", %{tmp_dir: dir} do
    refute RetentionSweepWorker.private?(
             sidecar(dir, "b.json", Jason.encode!(%{"metadata" => %{"source" => "pocketcasts"}}))
           )

    refute RetentionSweepWorker.private?(
             sidecar(dir, "c.json", Jason.encode!(%{"metadata" => %{"private" => false}}))
           )

    refute RetentionSweepWorker.private?(
             sidecar(dir, "d.json", Jason.encode!(%{"metadata" => %{"private" => "true"}}))
           )
  end

  test "sidecar ausente ou inválido não é privado (comportamento antigo preservado)", %{
    tmp_dir: dir
  } do
    refute RetentionSweepWorker.private?(Path.join(dir, "nao-existe.json"))
    refute RetentionSweepWorker.private?(sidecar(dir, "e.json", "{ lixo"))
  end
end
