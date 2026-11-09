defmodule Toscanini.PipelinePrivateTest do
  # async: false — mexe em variáveis de ambiente do processo.
  use ExUnit.Case, async: false

  alias Toscanini.Pipeline

  defp pipeline(params), do: %Pipeline{id: "p1", params: Jason.encode!(params)}

  setup do
    old_public = System.get_env("TOSCANINI_VOX_CONTENT_DIR")
    old_private = System.get_env("TOSCANINI_VOX_PRIVATE_DIR")
    System.put_env("TOSCANINI_VOX_CONTENT_DIR", "/repo/publico")
    System.put_env("TOSCANINI_VOX_PRIVATE_DIR", "/repo/privado")

    on_exit(fn ->
      restore("TOSCANINI_VOX_CONTENT_DIR", old_public)
      restore("TOSCANINI_VOX_PRIVATE_DIR", old_private)
    end)
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)

  test "private?/1 só é verdadeiro com params.private == true" do
    assert Pipeline.private?(pipeline(%{"private" => true}))
    refute Pipeline.private?(pipeline(%{"private" => false}))
    refute Pipeline.private?(pipeline(%{"private" => "true"}))
    refute Pipeline.private?(pipeline(%{}))
  end

  test "content_dir/1 usa o repo público por padrão e o privado quando private" do
    assert Pipeline.content_dir(pipeline(%{})) == "/repo/publico"
    assert Pipeline.content_dir(pipeline(%{"private" => true})) == "/repo/privado"
  end

  test "pipeline privado sem TOSCANINI_VOX_PRIVATE_DIR falha em vez de cair no repo público" do
    System.delete_env("TOSCANINI_VOX_PRIVATE_DIR")

    assert_raise System.EnvError, fn ->
      Pipeline.content_dir(pipeline(%{"private" => true}))
    end
  end
end
