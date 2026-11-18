defmodule Toscanini.Feeds.BackupTest do
  @moduledoc """
  render/parse são funções puras; restore/2 usa o sandbox do banco de teste e uma
  função `:subscribe` injetada (sem rede).
  """
  use Toscanini.DataCase, async: false

  alias Toscanini.{FeedSubscription, Feeds.Backup}

  defp sub(attrs) do
    struct(
      FeedSubscription,
      Map.merge(
        %{source: "pocketcasts", active: true, auto_annotate: false, hot_interval_min: 60, idle_interval_min: 1440},
        attrs
      )
    )
  end

  defp subs, do: [
    sub(%{title: "Calma Urgente", feed_ref: "aaaa-1", auto_annotate: true, check_days: ~s(["mon","tue"])}),
    sub(%{title: "Foo | Bar", feed_ref: "bbbb-2", active: false, check_days: nil}),
    sub(%{title: "NerdCast", feed_ref: "cccc-3", check_days: "[]", hot_interval_min: 30, idle_interval_min: 720})
  ]

  describe "render/1 e parse/1" do
    test "ida e volta preserva a configuração" do
      assert {:ok, rows} = subs() |> Backup.render() |> Backup.parse()

      assert [
               %{title: "Calma Urgente", feed_ref: "aaaa-1", auto_annotate: true, check_days: ["mon", "tue"], active: true},
               %{title: "Foo | Bar", feed_ref: "bbbb-2", active: false, check_days: []},
               %{title: "NerdCast", feed_ref: "cccc-3", hot_interval_min: 30, idle_interval_min: 720, check_days: []}
             ] = rows
    end

    test "check_days vazio vira 'sempre' e volta como lista vazia" do
      md = Backup.render([sub(%{title: "X", feed_ref: "x-1", check_days: nil})])
      assert md =~ "| sempre |"
      assert {:ok, [%{check_days: []}]} = Backup.parse(md)
    end

    test "a saída é determinística (mesma entrada, mesmo texto)" do
      assert Backup.render(subs()) == Backup.render(subs())
    end

    test "linha com número errado de colunas aponta a linha" do
      md = Backup.render(subs()) <> "| só | três | colunas |\n"
      assert {:error, {n, {:expected_columns, 8, 3}}} = Backup.parse(md)
      assert n > 8
    end

    test "booleano inválido é erro, não default" do
      md = "| T | pocketcasts | `r-1` | talvez | não | sempre | 60 | 1440 |\n"
      assert {:error, {1, {:bad_boolean, "talvez"}}} = Backup.parse(md)
    end

    test "texto sem tabela devolve lista vazia" do
      assert {:ok, []} = Backup.parse("# Só um título\n\nNada de tabela.\n")
    end
  end

  describe "restore/2" do
    @row %{
      title: "Novo", source: "pocketcasts", feed_ref: "new-1", active: true, auto_annotate: false,
      check_days: [], hot_interval_min: 60, idle_interval_min: 1440
    }

    test "chama subscribe com sync: false e conta as restauradas" do
      parent = self()

      fake = fn attrs, opts ->
        send(parent, {:subscribed, attrs.feed_ref, opts})
        {:ok, :fake}
      end

      assert %{restored: 1, skipped: 0, failed: []} = Backup.restore([@row], subscribe: fake)
      assert_received {:subscribed, "new-1", [sync: false]}
    end

    test "pula o que já existe no banco" do
      Repo.insert!(%FeedSubscription{id: Ecto.UUID.generate(), source: "pocketcasts", feed_ref: "new-1"})
      fake = fn _, _ -> flunk("não devia chamar subscribe") end
      assert %{restored: 0, skipped: 1, failed: []} = Backup.restore([@row], subscribe: fake)
    end

    test "falha de uma não impede as outras e fica registrada" do
      fake = fn
        %{feed_ref: "bad"}, _ -> {:error, :boom}
        _, _ -> {:ok, :fake}
      end

      rows = [%{@row | feed_ref: "bad"}, %{@row | feed_ref: "good"}]
      assert %{restored: 1, failed: [{"bad", :boom}]} = Backup.restore(rows, subscribe: fake)
    end

    test "dry_run não chama subscribe" do
      fake = fn _, _ -> flunk("não devia chamar subscribe") end
      assert %{restored: 1} = Backup.restore([@row], dry_run: true, subscribe: fake)
    end
  end

  describe "sync/0" do
    test "desligado no ambiente de teste (path nil)" do
      assert Backup.path() == nil
      assert Backup.sync() == :disabled
    end
  end
end
