defmodule Toscanini.ModelRouting do
  @moduledoc """
  Cadeias de modelos por caso de uso, com dois perfis completos (`anthropic` e
  `third-party`) e um perfil ativo. Editável em runtime, sem redeploy, no mesmo
  padrão do scheduler e do `FeedsConfig`.

  O arquivo vivo é `data/model_routing.json`. Sem ele (ou com ele ilegível), vale a
  semente versionada `priv/model_routing.default.json`, que também serve para
  restaurar o estado conhecido. Cada gravação guarda a versão anterior em
  `data/model_routing_backups/` (as últimas 30).

  Formato:

      %{
        "active"   => "third-party",
        "profiles" => ["anthropic", "third-party"],
        "cases"    => %{
          "podcast/episode" => %{
            "case" => "C5", "what" => "...", "note" => "...",
            "anthropic" => ["openrouter/..."], "third-party" => ["openrouter/..."]
          }
        }
      }

  Quem lê:

    * a vox-intelligence, por `GET /api/orchestrator/model-routing/resolved` (cache de
      60 s; cada gravação aqui pede um refresh imediato). Sem resposta, ela usa as
      constantes de cada preset.
    * o `AnnotateWorker` (`toscanini/annotate`).
    * o `model-profile.sh sync` da ClaudinhoSandbox (`claudinho/agent` e
      `claudinho/image`), porque o OpenClaw só lê o próprio `openclaw.json`.

  A transcrição de voz da vox-intelligence fica fora: precisa de modelo que aceite
  áudio e não muda com o perfil.
  """

  require Logger

  @file_name "model_routing.json"
  @backup_dir "model_routing_backups"
  @keep_backups 30
  @model_re ~r/^(openrouter|ollama|openai|anthropic|deepseek)\/\S+$/
  @catalog_url "https://openrouter.ai/api/v1/models"

  @doc "Caminho do arquivo vivo."
  def path, do: Path.join(data_dir(), @file_name)

  defp data_dir, do: Application.get_env(:toscanini, :data_dir, "data")

  defp seed_path do
    Application.get_env(:toscanini, :model_routing_seed) ||
      Application.app_dir(:toscanini, "priv/model_routing.default.json")
  end

  @doc "Documento atual: o arquivo vivo, ou a semente se ele faltar ou estiver inválido."
  def read do
    case read_json(path()) do
      {:ok, doc} ->
        doc

      :error ->
        case read_json(seed_path()) do
          {:ok, doc} -> doc
          :error -> %{"active" => nil, "profiles" => [], "cases" => %{}}
        end
    end
  end

  defp read_json(file) do
    with {:ok, raw} <- File.read(file),
         {:ok, %{} = doc} <- Jason.decode(raw),
         true <- valid_doc?(doc) do
      {:ok, doc}
    else
      _ -> :error
    end
  end

  defp valid_doc?(%{"active" => active, "profiles" => profiles, "cases" => cases})
       when is_binary(active) and is_list(profiles) and is_map(cases),
       do: active in profiles

  defp valid_doc?(_), do: false

  @doc "Perfil ativo."
  def active, do: read()["active"]

  @doc "Cadeia de cada caso no perfil ativo: `%{\"profile\" => p, \"chains\" => %{key => [model]}}`."
  def resolved(doc \\ read()) do
    profile = doc["active"]

    chains =
      for {key, entry} <- doc["cases"],
          chain = entry[profile],
          is_list(chain) and chain != [],
          into: %{},
          do: {key, chain}

    %{"profile" => profile, "chains" => chains}
  end

  @doc "Cadeia do caso `key` no perfil ativo, ou `nil`."
  def chain(key), do: resolved()["chains"][key]

  @doc "Troca o perfil ativo. `{:ok, doc}` ou `{:error, reason}`."
  def set_profile(profile) do
    doc = read()

    if profile in doc["profiles"] do
      write(%{doc | "active" => profile})
    else
      {:error, "unknown profile: #{inspect(profile)} (use: #{Enum.join(doc["profiles"], ", ")})"}
    end
  end

  @doc "Troca a cadeia de um caso num perfil. O caso precisa existir."
  def set_chain(key, profile, chain) do
    doc = read()

    cond do
      not Map.has_key?(doc["cases"], key) ->
        {:error, "unknown case: #{inspect(key)}"}

      profile not in doc["profiles"] ->
        {:error, "unknown profile: #{inspect(profile)} (use: #{Enum.join(doc["profiles"], ", ")})"}

      true ->
        with :ok <- validate_chain(chain) do
          write(put_in(doc, ["cases", key, profile], chain))
        end
    end
  end

  @doc "Cadeia válida: lista não vazia de `<provider>/<id>`."
  def validate_chain(chain) when is_list(chain) and chain != [] do
    if Enum.all?(chain, &(is_binary(&1) and Regex.match?(@model_re, &1))),
      do: :ok,
      else: {:error, "each model must be <provider>/<id>, provider in openrouter|ollama|openai|anthropic|deepseek"}
  end

  def validate_chain(_), do: {:error, "chain must be a non-empty list"}

  @doc """
  Modelos `openrouter/...` do perfil (default: o ativo) que o catálogo do OpenRouter
  não lista mais. `{:ok, [model]}`, ou `{:error, reason}` se o catálogo não respondeu.
  Teria pego o `claude-sonnet-4` retirado em 2026-11.
  """
  def missing_models(profile \\ nil, catalog_fun \\ &fetch_catalog/0) do
    doc = read()
    profile = profile || doc["active"]

    wanted =
      doc["cases"]
      |> Map.values()
      |> Enum.flat_map(&List.wrap(&1[profile]))
      |> Enum.filter(&String.starts_with?(&1, "openrouter/"))
      |> Enum.uniq()

    with {:ok, catalog} <- catalog_fun.() do
      {:ok, Enum.reject(wanted, &MapSet.member?(catalog, String.replace_prefix(&1, "openrouter/", "")))}
    end
  end

  defp fetch_catalog do
    case Req.get(@catalog_url, receive_timeout: 8_000, retry: false) do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
        {:ok, MapSet.new(data, & &1["id"])}

      {:ok, %{status: s}} ->
        {:error, "OpenRouter catalog HTTP #{s}"}

      {:error, e} ->
        {:error, Exception.message(e)}
    end
  end

  defp write(doc) do
    File.mkdir_p!(data_dir())
    backup_current()

    tmp = path() <> ".tmp"
    File.write!(tmp, Jason.encode!(doc, pretty: true))
    File.rename!(tmp, path())

    Logger.info("[ModelRouting] active profile: #{doc["active"]}")
    notify_refresh()
    {:ok, doc}
  end

  defp backup_current do
    if File.exists?(path()) do
      dir = Path.join(data_dir(), @backup_dir)
      File.mkdir_p!(dir)
      stamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^0-9TZ]/, "")
      File.cp!(path(), Path.join(dir, "model_routing-#{stamp}.json"))

      dir
      |> File.ls!()
      |> Enum.sort()
      |> Enum.drop(-@keep_backups)
      |> Enum.each(&File.rm(Path.join(dir, &1)))
    end
  end

  @doc "Backups existentes, do mais antigo ao mais novo."
  def backups do
    dir = Path.join(data_dir(), @backup_dir)

    case File.ls(dir) do
      {:ok, files} -> files |> Enum.sort() |> Enum.map(&Path.join(dir, &1))
      _ -> []
    end
  end

  # Pede à vox-intelligence que largue o cache agora, em vez de esperar os 60 s.
  # Melhor esforço: se falhar, o cache expira sozinho.
  defp notify_refresh do
    base = Application.get_env(:toscanini, :base_url)

    if base && Application.get_env(:toscanini, :model_routing_notify, true) do
      Task.start(fn ->
        Req.post("#{base}/api/vox-intelligence/routing/refresh", json: %{}, retry: false, receive_timeout: 3_000)
      end)
    end

    :ok
  end
end

