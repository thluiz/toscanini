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

  test "sem arquivo → defaults (safety 06:00 UTC, folga 10min)" do
    assert FeedsConfig.read() == %{"safety_hour_utc" => 6, "hot_grace_min" => 10}
    assert FeedsConfig.safety_hour_utc() == 6
    assert FeedsConfig.hot_grace_min() == 10
  end

  test "put safety_hour_utc persiste (preservando os outros campos)" do
    assert {:ok, cfg} = FeedsConfig.put(%{"safety_hour_utc" => 9})
    assert cfg == %{"safety_hour_utc" => 9, "hot_grace_min" => 10}
    assert FeedsConfig.safety_hour_utc() == 9
  end

  test "put hot_grace_min persiste" do
    assert {:ok, cfg} = FeedsConfig.put(%{"hot_grace_min" => 5})
    assert cfg["hot_grace_min"] == 5
    assert FeedsConfig.hot_grace_min() == 5
  end

  test "put com as duas chaves de uma vez" do
    assert {:ok, cfg} = FeedsConfig.put(%{"safety_hour_utc" => 8, "hot_grace_min" => 15})
    assert cfg == %{"safety_hour_utc" => 8, "hot_grace_min" => 15}
  end

  test "rejeita safety_hour_utc fora de 0..23" do
    assert {:error, _} = FeedsConfig.put(%{"safety_hour_utc" => 24})
    assert {:error, _} = FeedsConfig.put(%{"safety_hour_utc" => -1})
    assert FeedsConfig.safety_hour_utc() == 6
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
    assert cfg["safety_hour_utc"] == 6
    assert cfg["hot_grace_min"] == 10
  end
end
