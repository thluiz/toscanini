defmodule Toscanini.FeedsTest do
  @moduledoc """
  Testes unitários das funções puras de Feeds — cadência (due?/2) e seleção de
  episódios novos por watermark. Não tocam rede nem DB.
  """
  use ExUnit.Case, async: true

  alias Toscanini.{Feeds, FeedSubscription}

  # Quinta-feira, 2026-07-16 12:00:00 UTC (day_of_week = 4 → "thu")
  @thu ~U[2026-07-16 12:00:00Z]
  # Sexta-feira, 2026-07-17 12:00:00 UTC → "fri"
  @fri ~U[2026-07-17 12:00:00Z]

  defp sub(attrs), do: struct(FeedSubscription, attrs)

  describe "due?/2 — janela quente vs idle" do
    test "nunca checado → sempre devido" do
      s = sub(check_days: ~s(["thu"]), hot_interval_min: 60, idle_interval_min: 1440, last_checked_at: nil)
      assert Feeds.due?(s, @thu)
      assert Feeds.due?(s, @fri)
    end

    test "dia quente: devido quando passou hot_interval_min" do
      s = sub(
        check_days: ~s(["thu"]),
        hot_interval_min: 60,
        idle_interval_min: 1440,
        last_checked_at: DateTime.add(@thu, -61, :minute)
      )
      assert Feeds.due?(s, @thu)
    end

    test "dia quente: NÃO devido antes de hot_interval_min" do
      s = sub(
        check_days: ~s(["thu"]),
        hot_interval_min: 60,
        idle_interval_min: 1440,
        last_checked_at: DateTime.add(@thu, -30, :minute)
      )
      refute Feeds.due?(s, @thu)
    end

    test "fora da janela: usa idle_interval_min (não devido após 1h)" do
      s = sub(
        check_days: ~s(["thu"]),
        hot_interval_min: 60,
        idle_interval_min: 1440,
        last_checked_at: DateTime.add(@fri, -61, :minute)
      )
      refute Feeds.due?(s, @fri)
    end

    test "fora da janela: devido após idle_interval_min" do
      s = sub(
        check_days: ~s(["thu"]),
        hot_interval_min: 60,
        idle_interval_min: 1440,
        last_checked_at: DateTime.add(@fri, -1500, :minute)
      )
      assert Feeds.due?(s, @fri)
    end

    test "check_days vazio → janela quente sempre ligada (usa hot_interval)" do
      s = sub(
        check_days: nil,
        hot_interval_min: 60,
        idle_interval_min: 1440,
        last_checked_at: DateTime.add(@fri, -61, :minute)
      )
      assert Feeds.due?(s, @fri)
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
