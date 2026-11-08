defmodule Toscanini.SchedulerTest do
  use ExUnit.Case, async: true

  alias Toscanini.Scheduler

  # 2026-11-07 é sábado, 2026-11-09 é segunda.
  @sat ~N[2026-11-07 15:00:00]
  @mon ~N[2026-11-09 15:00:00]

  defp windows do
    [
      %{"days" => ["sat", "sun"], "from" => 0, "to" => 24, "limit" => 3, "gpu" => true},
      %{"from" => 0, "to" => 12, "limit" => 3, "gpu" => true},
      %{"from" => 12, "to" => 20, "limit" => 2, "gpu" => false},
      %{"from" => 20, "to" => 24, "limit" => 3, "gpu" => true}
    ]
  end

  describe "window_for/2" do
    test "fim de semana: GPU livre o dia todo, inclusive 12h-20h" do
      assert %{"gpu" => true, "limit" => 3} = Scheduler.window_for(windows(), @sat)
      assert %{"gpu" => true} = Scheduler.window_for(windows(), ~N[2026-11-08 12:00:00])
    end

    test "dia útil: sem GPU de 12h às 20h" do
      assert %{"gpu" => false, "limit" => 2} = Scheduler.window_for(windows(), @mon)
      assert %{"gpu" => false} = Scheduler.window_for(windows(), ~N[2026-11-09 12:00:00])
      assert %{"gpu" => false} = Scheduler.window_for(windows(), ~N[2026-11-09 19:59:59])
    end

    test "dia útil: GPU de manhã e à noite; 'to' é exclusivo" do
      assert %{"gpu" => true} = Scheduler.window_for(windows(), ~N[2026-11-09 00:00:00])
      assert %{"gpu" => true} = Scheduler.window_for(windows(), ~N[2026-11-09 11:59:59])
      assert %{"gpu" => true} = Scheduler.window_for(windows(), ~N[2026-11-09 20:00:00])
      assert %{"gpu" => true} = Scheduler.window_for(windows(), ~N[2026-11-09 23:59:59])
    end

    test "janela sem 'days' vale todos os dias" do
      only = [%{"from" => 0, "to" => 24, "limit" => 1, "gpu" => false}]
      assert %{"limit" => 1} = Scheduler.window_for(only, @sat)
      assert %{"limit" => 1} = Scheduler.window_for(only, @mon)
    end

    test "sem janela que case, devolve nil" do
      assert Scheduler.window_for([%{"from" => 0, "to" => 9, "limit" => 1}], @mon) == nil
      assert Scheduler.window_for(nil, @mon) == nil
    end
  end

  describe "validate_windows/1" do
    test "aceita janelas com e sem 'days'" do
      assert Scheduler.validate_windows(windows()) == :ok
    end

    test "rejeita dia desconhecido, lista vazia e tipo errado" do
      base = %{"from" => 0, "to" => 24, "limit" => 1}
      assert {:error, _} = Scheduler.validate_windows([Map.put(base, "days", ["xyz"])])
      assert {:error, _} = Scheduler.validate_windows([Map.put(base, "days", [])])
      assert {:error, _} = Scheduler.validate_windows([Map.put(base, "days", "sat")])
    end

    test "rejeita campos obrigatórios ausentes, limite negativo e não-lista" do
      assert {:error, _} = Scheduler.validate_windows([%{"from" => 0, "to" => 24}])
      assert {:error, _} = Scheduler.validate_windows([%{"from" => 0, "to" => 24, "limit" => -1}])
      assert {:error, _} = Scheduler.validate_windows(%{})
    end
  end
end
