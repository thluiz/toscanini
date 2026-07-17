defmodule Toscanini.FeedsTest do
  @moduledoc """
  Testes unitários das funções puras de Feeds — cadência (due?/2) e seleção de
  episódios novos por watermark. Não tocam rede nem DB.
  """
  use ExUnit.Case, async: true

  alias Toscanini.{Feeds, FeedSubscription}

  # Quinta-feira, 2026-07-16 12:00:00 UTC (day_of_week = 4 → "thu"): dia quente p/ check_days=[thu]
  @thu ~U[2026-07-16 12:00:00Z]
  # Sexta-feira (dia idle p/ check_days=[thu]).
  # 06:00 UTC = hora-âncora default da rede de segurança (FeedsConfig, sem arquivo).
  @fri_safety ~U[2026-07-17 06:00:00Z]
  # 12:00 UTC = fora da hora-âncora.
  @fri_noon ~U[2026-07-17 12:00:00Z]

  defp sub(attrs), do: struct(FeedSubscription, attrs)

  describe "due?/2 — janela quente (hot_interval)" do
    test "dia quente + nunca checado → devido" do
      s = sub(check_days: ~s(["thu"]), hot_interval_min: 60, last_checked_at: nil)
      assert Feeds.due?(s, @thu)
    end

    test "dia quente: devido quando passou hot_interval_min" do
      s = sub(check_days: ~s(["thu"]), hot_interval_min: 60, last_checked_at: DateTime.add(@thu, -61, :minute))
      assert Feeds.due?(s, @thu)
    end

    test "dia quente: NÃO devido antes de hot_interval_min - folga" do
      s = sub(check_days: ~s(["thu"]), hot_interval_min: 60, last_checked_at: DateTime.add(@thu, -30, :minute))
      refute Feeds.due?(s, @thu)
    end

    test "dia quente: devido com folga (55min, hot_interval 60, grace default 10 → limiar 50)" do
      # Sem a folga, 55 < 60 pularia o sweep (o bug do 'every 2h'); com folga 10, 55 >= 50 → devido.
      s = sub(check_days: ~s(["thu"]), hot_interval_min: 60, last_checked_at: DateTime.add(@thu, -55, :minute))
      assert Feeds.due?(s, @thu)
    end

    test "check_days vazio → janela quente sempre ligada (usa hot_interval mesmo fora da hora-âncora)" do
      s = sub(check_days: nil, hot_interval_min: 60, last_checked_at: DateTime.add(@fri_noon, -61, :minute))
      assert Feeds.due?(s, @fri_noon)
    end
  end

  describe "due?/2 — rede de segurança diária (hora-âncora 06:00 UTC, default)" do
    test "dia idle, na hora-âncora, >12h desde o último check → devido" do
      s = sub(check_days: ~s(["thu"]), hot_interval_min: 60, last_checked_at: DateTime.add(@fri_safety, -20, :hour))
      assert Feeds.due?(s, @fri_safety)
    end

    test "dia idle, na hora-âncora, mas checado há 2h → NÃO devido (gap < 12h)" do
      s = sub(check_days: ~s(["thu"]), hot_interval_min: 60, last_checked_at: DateTime.add(@fri_safety, -2, :hour))
      refute Feeds.due?(s, @fri_safety)
    end

    test "dia idle, FORA da hora-âncora → NÃO devido mesmo com 20h desde o último check" do
      s = sub(check_days: ~s(["thu"]), hot_interval_min: 60, last_checked_at: DateTime.add(@fri_noon, -20, :hour))
      refute Feeds.due?(s, @fri_noon)
    end

    test "dia idle, nunca checado: devido só na hora-âncora" do
      s = sub(check_days: ~s(["thu"]), hot_interval_min: 60, last_checked_at: nil)
      assert Feeds.due?(s, @fri_safety)
      refute Feeds.due?(s, @fri_noon)
    end
  end

  describe "new_episodes/2 — delta por watermark (backfill off)" do
    @watermark ~U[2026-07-10 00:00:00Z]

    @episodes [
      %{"uuid" => "old", "published" => "2026-07-05T10:00:00Z"},
      %{"uuid" => "same", "published" => "2026-07-10T00:00:00Z"},
      %{"uuid" => "new1", "published" => "2026-07-12T08:00:00Z"},
      %{"uuid" => "new2", "published" => "2026-07-14T09:00:00Z"}
    ]

    test "só episódios estritamente após o watermark entram" do
      got = Feeds.new_episodes(@episodes, @watermark) |> Enum.map(fn {ep, _dt} -> ep["uuid"] end)
      assert got == ["new1", "new2"]
    end

    test "watermark igual ao published NÃO reprocessa (estritamente maior)" do
      refute Enum.any?(Feeds.new_episodes(@episodes, @watermark), fn {ep, _} -> ep["uuid"] == "same" end)
    end

    test "watermark nil → nada entra (guarda de backfill)" do
      assert Feeds.new_episodes(@episodes, nil) == []
    end

    test "ignora episódios com published inválido/ausente" do
      eps = [%{"uuid" => "bad", "published" => "não-é-data"}, %{"uuid" => "nil", "published" => nil}]
      assert Feeds.new_episodes(eps, @watermark) == []
    end

    test "ordena ascendente por data de publicação" do
      shuffled = Enum.reverse(@episodes)
      got = Feeds.new_episodes(shuffled, @watermark) |> Enum.map(fn {ep, _} -> ep["uuid"] end)
      assert got == ["new1", "new2"]
    end
  end

  describe "infer_check_days/2 — janela quente pela cadência" do
    # Helper: gera N episódios semanais recuando a partir de uma âncora, num dado
    # dia-da-semana, com deslocamento opcional (para simular drift de meia-noite).
    defp weekly(anchor, n, step_days \\ 7) do
      for i <- 0..(n - 1) do
        %{"uuid" => "e#{i}", "published" => DateTime.add(anchor, -i * step_days, :day) |> DateTime.to_iso8601()}
      end
    end

    test "semanal numa terça → [\"tue\"]" do
      # 2026-07-14 é terça-feira.
      eps = weekly(~U[2026-07-14 09:00:00Z], 10)
      assert Feeds.infer_check_days(eps) == ["tue"]
    end

    test "amostra pequena (< 4) → [] (hot sempre ligado)" do
      eps = weekly(~U[2026-07-14 09:00:00Z], 3)
      assert Feeds.infer_check_days(eps) == []
    end

    test "diário (≥ 5 dias distintos) → [] (hot sempre ligado)" do
      eps = weekly(~U[2026-07-14 09:00:00Z], 12, 1)
      assert Feeds.infer_check_days(eps) == []
    end

    test "drift de meia-noite: mistura seg/ter puxa o vizinho" do
      # 6 terças + 6 segundas → dois dias dominantes adjacentes.
      ter = weekly(~U[2026-07-14 09:00:00Z], 6)
      seg = weekly(~U[2026-07-13 23:30:00Z], 6)
      assert Feeds.infer_check_days(ter ++ seg) == ["mon", "tue"]
    end

    test "ignora published inválido/ausente e ordena na semana" do
      eps =
        weekly(~U[2026-07-16 09:00:00Z], 8) ++
          [%{"uuid" => "bad", "published" => "xx"}, %{"uuid" => "nil", "published" => nil}]

      # 2026-07-16 é quinta.
      assert Feeds.infer_check_days(eps) == ["thu"]
    end
  end

  describe "latest_episode/1" do
    test "devolve a data máxima e o uuid do mais recente" do
      eps = [
        %{"uuid" => "a", "published" => "2026-07-05T10:00:00Z"},
        %{"uuid" => "b", "published" => "2026-07-14T09:00:00Z"}
      ]
      assert {dt, "b"} = Feeds.latest_episode(eps)
      assert DateTime.compare(dt, ~U[2026-07-14 09:00:00Z]) == :eq
    end

    test "lista vazia → {nil, nil}" do
      assert Feeds.latest_episode([]) == {nil, nil}
    end
  end
end
