defmodule Toscanini.FeedsConfigTest do
  @moduledoc "Config runtime dos feeds (arquivo JSON em data/). async: false — mexe em Application env + FS."
  use ExUnit.Case, async: false

  alias Toscanini.FeedsConfig

  setup do
    tmp = Path.join(System.tmp_dir!(), "feeds_cfg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:toscanini, :data_dir)
    Application.put_env(:toscanini, :data_dir, tmp)

    on_exit(fn ->
      if prev, do: Application.put_env(:toscanini, :data_dir, prev), else: Application.delete_env(:toscanini, :data_dir)
      File.rm_rf!(tmp)
    end)

    %{dir: tmp}
  end

  test "sem arquivo → defaults (safety 03:00 e 15:00 UTC, folga 10min)" do
    assert FeedsConfig.read() == %{"safety_hours_utc" => [3, 15], "hot_grace_min" => 10}
    assert FeedsConfig.safety_hours_utc() == [3, 15]
    assert FeedsConfig.hot_grace_min() == 10
  end

  test "put safety_hours_utc persiste ordenado e sem repetição" do
    assert {:ok, cfg} = FeedsConfig.put(%{"safety_hours_utc" => [15, 3, 15]})
    assert cfg == %{"safety_hours_utc" => [3, 15], "hot_grace_min" => 10}
    assert FeedsConfig.safety_hours_utc() == [3, 15]
  end

  test "put safety_hour_utc (legado, inteiro) vira safety_hours_utc [h]" do
    assert {:ok, cfg} = FeedsConfig.put(%{"safety_hour_utc" => 9})
    assert cfg == %{"safety_hours_utc" => [9], "hot_grace_min" => 10}
    assert FeedsConfig.safety_hours_utc() == [9]
  end

  test "arquivo antigo com safety_hour_utc é lido como safety_hours_utc [h]", %{dir: dir} do
    File.write!(Path.join(dir, "feeds_config.json"), ~s({"safety_hour_utc": 2, "hot_grace_min": 10}))
    assert FeedsConfig.read() == %{"safety_hours_utc" => [2], "hot_grace_min" => 10}

    # um put novo grava só a chave nova
    assert {:ok, %{"safety_hours_utc" => [3, 15]} = cfg} = FeedsConfig.put(%{"safety_hours_utc" => [3, 15]})
    refute Map.has_key?(cfg, "safety_hour_utc")
    refute File.read!(Path.join(dir, "feeds_config.json")) =~ "safety_hour_utc\""
  end

  test "safety_min_gap_hours = metade do menor intervalo entre âncoras" do
    assert FeedsConfig.safety_min_gap_hours([3, 15]) == 6
    assert FeedsConfig.safety_min_gap_hours([6]) == 12
    assert FeedsConfig.safety_min_gap_hours([2, 6, 18]) == 2
    assert FeedsConfig.safety_min_gap_hours([23, 1]) == 1
  end

  test "put hot_grace_min persiste" do
    assert {:ok, cfg} = FeedsConfig.put(%{"hot_grace_min" => 5})
    assert cfg["hot_grace_min"] == 5
    assert FeedsConfig.hot_grace_min() == 5
  end

  test "put com as duas chaves de uma vez" do
    assert {:ok, cfg} = FeedsConfig.put(%{"safety_hours_utc" => [8, 20], "hot_grace_min" => 15})
    assert cfg == %{"safety_hours_utc" => [8, 20], "hot_grace_min" => 15}
  end

  test "rejeita horas fora de 0..23 ou lista vazia" do
    assert {:error, _} = FeedsConfig.put(%{"safety_hour_utc" => 24})
    assert {:error, _} = FeedsConfig.put(%{"safety_hour_utc" => -1})
    assert {:error, _} = FeedsConfig.put(%{"safety_hours_utc" => [3, 24]})
    assert {:error, _} = FeedsConfig.put(%{"safety_hours_utc" => []})
    assert {:error, _} = FeedsConfig.put(%{"safety_hours_utc" => 3})
    assert FeedsConfig.safety_hours_utc() == [3, 15]
  end

  test "rejeita hot_grace_min fora de 0..59" do
    assert {:error, _} = FeedsConfig.put(%{"hot_grace_min" => 60})
    assert FeedsConfig.hot_grace_min() == 10
  end

  test "rejeita valor não-inteiro" do
    assert {:error, _} = FeedsConfig.put(%{"safety_hour_utc" => "seis"})
  end

  test "put sem chave conhecida é no-op válido (não quebra)" do
    assert {:ok, cfg} = FeedsConfig.put(%{"foo" => 1})
    assert cfg["safety_hours_utc"] == [3, 15]
    assert cfg["hot_grace_min"] == 10
  end
end
