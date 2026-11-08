defmodule Toscanini.GpuCooldownTest do
  use ExUnit.Case, async: true

  alias Toscanini.GpuCooldown
  alias Toscanini.Workers.TranscribeWorker

  @moduletag :tmp_dir

  test "sem arquivo, não há cooldown", %{tmp_dir: dir} do
    refute GpuCooldown.active?(Path.join(dir, "gpu_cooldown.json"), 1_000)
  end

  test "start abre 15 min de cooldown e depois expira", %{tmp_dir: dir} do
    path = Path.join(dir, "gpu_cooldown.json")

    assert GpuCooldown.start(path, 1_000) == 1_000 + 15 * 60
    assert GpuCooldown.active?(path, 1_000)
    assert GpuCooldown.active?(path, 1_000 + 15 * 60 - 1)
    refute GpuCooldown.active?(path, 1_000 + 15 * 60)
  end

  test "novo abort reinicia a contagem dos 15 min", %{tmp_dir: dir} do
    path = Path.join(dir, "gpu_cooldown.json")

    GpuCooldown.start(path, 1_000)
    GpuCooldown.start(path, 1_500)
    assert GpuCooldown.active?(path, 1_000 + 15 * 60 + 1)
    refute GpuCooldown.active?(path, 1_500 + 15 * 60)
  end

  test "arquivo corrompido não bloqueia a GPU", %{tmp_dir: dir} do
    path = Path.join(dir, "gpu_cooldown.json")
    File.write!(path, "{ não é json")
    refute GpuCooldown.active?(path, 1_000)
  end

  describe "TranscribeWorker.classify_exit/2" do
    test "exit 0 segue o fluxo normal" do
      assert TranscribeWorker.classify_exit(0, true) == :ok
      assert TranscribeWorker.classify_exit(0, false) == :ok
    end

    test "134 com a GPU em jogo vira cooldown + retorno à fila" do
      assert TranscribeWorker.classify_exit(134, true) == :gpu_abort
    end

    test "134 fora da GPU (CPU, janela sem GPU, cooldown aberto) é erro comum" do
      assert {:error, "whisper worker exited with code 134"} =
               TranscribeWorker.classify_exit(134, false)
    end

    test "outros códigos continuam sendo erro" do
      assert {:error, "whisper worker exited with code 1"} =
               TranscribeWorker.classify_exit(1, true)
    end
  end
end
