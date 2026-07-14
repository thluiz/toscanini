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

  test "sem arquivo → default 06:00 UTC" do
    assert FeedsConfig.read() == %{"safety_hour_utc" => 6}
    assert FeedsConfig.safety_hour_utc() == 6
  end

  test "put persiste e read devolve o novo valor" do
    assert {:ok, %{"safety_hour_utc" => 9}} = FeedsConfig.put(%{"safety_hour_utc" => 9})
    assert FeedsConfig.safety_hour_utc() == 9
  end

  test "rejeita hora fora de 0..23" do
    assert {:error, _} = FeedsConfig.put(%{"safety_hour_utc" => 24})
    assert {:error, _} = FeedsConfig.put(%{"safety_hour_utc" => -1})
    assert FeedsConfig.safety_hour_utc() == 6
  end

  test "rejeita valor não-inteiro" do
    assert {:error, _} = FeedsConfig.put(%{"safety_hour_utc" => "seis"})
  end

  test "put sem a chave conhecida é no-op válido (não quebra)" do
    assert {:ok, cfg} = FeedsConfig.put(%{"foo" => 1})
    assert cfg["safety_hour_utc"] == 6
  end
end
