defmodule Toscanini.ModelRoutingTest do
  @moduledoc "Roteamento de modelos (arquivo JSON em data/). async: false — mexe em Application env + FS."
  use ExUnit.Case, async: false

  alias Toscanini.ModelRouting

  @seed Path.expand("../../priv/model_routing.default.json", __DIR__)

  setup do
    tmp = Path.join(System.tmp_dir!(), "model_routing_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = for k <- [:data_dir, :model_routing_seed, :model_routing_notify], into: %{}, do: {k, Application.get_env(:toscanini, k)}
    Application.put_env(:toscanini, :data_dir, tmp)
    Application.put_env(:toscanini, :model_routing_seed, @seed)
    Application.put_env(:toscanini, :model_routing_notify, false)

    on_exit(fn ->
      for {k, v} <- prev do
        if v, do: Application.put_env(:toscanini, k, v), else: Application.delete_env(:toscanini, k)
      end

      File.rm_rf!(tmp)
    end)

    %{dir: tmp}
  end

  describe "semente versionada" do
    test "todo caso tem cadeia válida nos dois perfis" do
      doc = ModelRouting.read()
      assert doc["profiles"] == ["anthropic", "third-party"]
      assert map_size(doc["cases"]) >= 15

      for {key, entry} <- doc["cases"], profile <- doc["profiles"] do
        assert ModelRouting.validate_chain(entry[profile]) == :ok, "#{key} / #{profile}"
        assert is_binary(entry["case"]), "#{key} sem número de caso"
      end
    end

    test "perfil third-party não tem Anthropic fora dos casos que a mantêm de propósito" do
      kept = ["claudinho/image", "podcast/episode-verify", "scholion/webclip-summary"]

      for {key, chain} <- ModelRouting.resolved()["chains"], key not in kept do
        refute Enum.any?(chain, &String.contains?(&1, "anthropic/")), "#{key}: #{inspect(chain)}"
      end
    end

    test "DeepSeek nunca aparece em anotação nem etimologia" do
      doc = ModelRouting.read()

      for key <- ["toscanini/annotate", "podcast/suggest-annotations", "podcast/annotate", "scholion/etymology-note"],
          profile <- doc["profiles"] do
        refute Enum.any?(doc["cases"][key][profile], &String.contains?(&1, "deepseek")), "#{key} / #{profile}"
      end
    end

    test "perfil anthropic põe a Anthropic na frente onde ela é usada" do
      {:ok, _} = ModelRouting.set_profile("anthropic")
      chains = ModelRouting.resolved()["chains"]
      assert hd(chains["claudinho/agent"]) == "openrouter/anthropic/claude-sonnet-5.5"
      assert hd(chains["toscanini/annotate"]) == "openrouter/anthropic/claude-sonnet-5.5"
      assert hd(chains["scholion/quote-note"]) == "openrouter/anthropic/claude-opus-5.5"
      # o resumo de episódio começa pelo DeepSeek nos dois perfis
      assert hd(chains["podcast/episode"]) == "openrouter/deepseek/deepseek-v4-pro"
    end
  end

  test "sem arquivo vivo → semente, perfil third-party" do
    assert ModelRouting.active() == "third-party"
    assert ModelRouting.chain("toscanini/annotate") == ["openrouter/openai/gpt-5.1", "openrouter/openai/gpt-5.2"]
  end

  test "set_profile persiste e a troca de ida e volta restaura o estado", %{dir: dir} do
    before = ModelRouting.resolved()
    assert {:ok, %{"active" => "anthropic"}} = ModelRouting.set_profile("anthropic")
    assert File.exists?(Path.join(dir, "model_routing.json"))
    assert ModelRouting.active() == "anthropic"
    assert {:ok, _} = ModelRouting.set_profile("third-party")
    assert ModelRouting.resolved() == before
  end

  test "perfil desconhecido não grava nada", %{dir: dir} do
    assert {:error, msg} = ModelRouting.set_profile("openai-only")
    assert msg =~ "unknown profile"
    refute File.exists?(Path.join(dir, "model_routing.json"))
  end

  test "cada gravação guarda a versão anterior" do
    {:ok, _} = ModelRouting.set_profile("anthropic")
    assert ModelRouting.backups() == []
    {:ok, _} = ModelRouting.set_profile("third-party")
    assert [backup] = ModelRouting.backups()
    assert backup |> File.read!() |> Jason.decode!() |> Map.get("active") == "anthropic"
  end

  test "set_chain troca um caso num perfil, sem mexer no outro" do
    assert {:ok, _} = ModelRouting.set_chain("toscanini/annotate", "third-party", ["openrouter/openai/gpt-5.1"])
    assert ModelRouting.chain("toscanini/annotate") == ["openrouter/openai/gpt-5.1"]
    assert hd(ModelRouting.read()["cases"]["toscanini/annotate"]["anthropic"]) == "openrouter/anthropic/claude-sonnet-5.5"
  end

  test "set_chain recusa caso, perfil ou cadeia inválidos" do
    assert {:error, "unknown case" <> _} = ModelRouting.set_chain("nope", "third-party", ["openrouter/x/y"])
    assert {:error, "unknown profile" <> _} = ModelRouting.set_chain("default", "nope", ["openrouter/x/y"])
    assert {:error, _} = ModelRouting.set_chain("default", "third-party", [])
    assert {:error, _} = ModelRouting.set_chain("default", "third-party", ["gpt-5.2"])
  end

  test "arquivo vivo corrompido → volta à semente", %{dir: dir} do
    File.write!(Path.join(dir, "model_routing.json"), "{not json")
    assert ModelRouting.active() == "third-party"
    File.write!(Path.join(dir, "model_routing.json"), ~s({"active": "x", "profiles": ["a"], "cases": {}}))
    assert ModelRouting.active() == "third-party"
  end

  test "missing_models acusa modelo fora do catálogo e respeita catálogo indisponível" do
    catalog = fn -> {:ok, MapSet.new(["openai/gpt-5.2"])} end
    assert {:ok, missing} = ModelRouting.missing_models("third-party", catalog)
    assert "openrouter/openai/gpt-5.1" in missing
    refute "openrouter/openai/gpt-5.2" in missing
    refute Enum.any?(missing, &String.starts_with?(&1, "ollama/"))

    assert {:error, "down"} = ModelRouting.missing_models("third-party", fn -> {:error, "down"} end)
  end
end

