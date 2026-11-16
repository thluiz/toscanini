defmodule ToscaniniWeb.ModelRoutingController do
  @moduledoc "Roteamento de modelos por caso de uso (ver `Toscanini.ModelRouting`)."
  use ToscaniniWeb, :controller

  alias Toscanini.ModelRouting

  # GET /model-routing — documento inteiro + cadeias do perfil ativo
  def show(conn, _params) do
    doc = ModelRouting.read()
    json(conn, Map.put(doc, "resolved", ModelRouting.resolved(doc)["chains"]))
  end

  # GET /model-routing/resolved — só o perfil ativo (o que a vox-intelligence lê)
  def resolved(conn, _params), do: json(conn, ModelRouting.resolved())

  # PUT /model-routing/profile — {"profile": "anthropic" | "third-party"}
  def set_profile(conn, %{"profile" => profile}) do
    case ModelRouting.set_profile(profile) do
      {:ok, doc} ->
        json(conn, %{ok: true, active: doc["active"], warnings: catalog_warnings(doc["active"])})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: reason})
    end
  end

  def set_profile(conn, _params),
    do: conn |> put_status(422) |> json(%{error: "missing profile"})

  # PUT /model-routing/cases/*key — {"profile": "...", "chain": ["openrouter/..."]}
  def set_case(conn, %{"key" => parts, "profile" => profile, "chain" => chain}) do
    key = Enum.join(List.wrap(parts), "/")

    case ModelRouting.set_chain(key, profile, chain) do
      {:ok, doc} ->
        json(conn, %{ok: true, case: key, profile: profile, chain: doc["cases"][key][profile],
                     warnings: catalog_warnings(profile)})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: reason})
    end
  end

  def set_case(conn, _params),
    do: conn |> put_status(422) |> json(%{error: "missing profile or chain"})

  defp catalog_warnings(profile) do
    if Application.get_env(:toscanini, :model_routing_catalog_check, true),
      do: check_catalog(profile),
      else: []
  end

  defp check_catalog(profile) do
    case ModelRouting.missing_models(profile) do
      {:ok, []} -> []
      {:ok, missing} -> ["not in the OpenRouter catalog: " <> Enum.join(missing, ", ")]
      {:error, reason} -> ["catalog check skipped: #{reason}"]
    end
  end
end

