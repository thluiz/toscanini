defmodule Toscanini.TranscriptCheckTest do
  use ExUnit.Case, async: true

  alias Toscanini.TranscriptCheck

  defp ts(secs) do
    h = div(secs, 3600)
    m = div(rem(secs, 3600), 60)
    s = rem(secs, 60)
    :io_lib.format("[~2..0B:~2..0B:~2..0B]", [h, m, s]) |> to_string()
  end

  defp lines(pairs), do: Enum.map_join(pairs, "\n", fn {t, text} -> "#{ts(t)} #{text}" end) <> "\n"

  test "transcrição normal passa" do
    t = lines(for i <- 0..99, do: {i * 30, "frase número #{i}"})
    assert TranscriptCheck.check(t, 3000) == :ok
  end

  test "loop de alucinação (episódio Barcelona) é rejeitado" do
    t =
      lines(
        (for i <- 0..11, do: {i * 30, "Добро пожаловать на наш канал!"}) ++
          [{330, "Субтитры подогнал «Симон»"}, {360, "Продолжение следует..."}]
      )

    assert {:error, msg} = TranscriptCheck.check(t, 376)
    assert msg =~ "loop"
    assert msg =~ "12/14"
  end

  test "loop parcial de '.' é rejeitado" do
    t = lines((for i <- 0..39, do: {i * 5, "fala #{i}"}) ++ for(i <- 40..119, do: {i * 5, "."}))
    assert {:error, msg} = TranscriptCheck.check(t, 600)
    assert msg =~ "loop"
  end

  test "uma palavra por linha não é confundida com loop" do
    words = ~w[the cat sat on the mat and the dog ran to the park with a ball]
    t = words |> Stream.cycle() |> Enum.take(600) |> Enum.with_index(fn w, i -> {i, w} end) |> lines()
    assert TranscriptCheck.check(t, 610) == :ok
  end

  test "transcrição truncada é rejeitada" do
    t = lines(for i <- 0..61, do: {i * 5, "frase #{i}"})
    assert {:error, msg} = TranscriptCheck.check(t, 2540)
    assert msg =~ "truncada"
  end

  test "sem duração confiável, cobertura não é checada" do
    t = lines(for i <- 0..61, do: {i * 5, "frase #{i}"})
    assert TranscriptCheck.check(t, 0) == :ok
    assert TranscriptCheck.check(t, nil) == :ok
  end

  test "áudio curto (< 300s) não checa cobertura" do
    t = lines(for i <- 0..19, do: {i, "frase #{i}"})
    assert TranscriptCheck.check(t, 200) == :ok
  end
end
