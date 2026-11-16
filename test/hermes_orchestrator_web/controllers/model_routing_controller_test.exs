defmodule ToscaniniWeb.ModelRoutingControllerTest do
  # Mesmo arranjo do WebclipControllersTest: ConnTest montado à mão.
  use Toscanini.DataCase, async: false
  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint ToscaniniWeb.Endpoint
  @seed Path.expand("../../../priv/model_routing.default.json", __DIR__)

  setup do
    tmp = Path.join(System.tmp_dir!(), "model_routing_ctl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    keys = [:data_dir, :model_routing_seed, :model_routing_notify, :model_routing_catalog_check]
    prev = for k <- keys, into: %{}, do: {k, Application.get_env(:toscanini, k)}
    Application.put_env(:toscanini, :data_dir, tmp)
    Application.put_env(:toscanini, :model_routing_seed, @seed)
    Application.put_env(:toscanini, :model_routing_notify, false)
    Application.put_env(:toscanini, :model_routing_catalog_check, false)

    on_exit(fn ->
      for {k, v} <- prev do
        if v, do: Application.put_env(:toscanini, k, v), else: Application.delete_env(:toscanini, k)
      end

      File.rm_rf!(tmp)
    end)

    {:ok, conn: build_conn() |> put_req_header("accept", "application/json")}
  end

  test "GET /resolved devolve o perfil ativo e as cadeias", %{conn: conn} do
    body = json_response(get(conn, "/api/orchestrator/model-routing/resolved"), 200)
    assert body["profile"] == "third-party"
    assert body["chains"]["toscanini/annotate"] == ["openrouter/openai/gpt-5.2", "openrouter/openai/gpt-5.1"]
  end

  test "GET / devolve o documento inteiro com resolved", %{conn: conn} do
    body = json_response(get(conn, "/api/orchestrator/model-routing"), 200)
    assert body["active"] == "third-party"
    assert body["cases"]["podcast/episode"]["case"] == "C5"
    assert is_map(body["resolved"])
  end

  test "PUT /profile troca e volta", %{conn: conn} do
    assert %{"ok" => true, "active" => "anthropic", "warnings" => []} =
             json_response(put(conn, "/api/orchestrator/model-routing/profile", %{"profile" => "anthropic"}), 200)

    body = json_response(get(build_conn(), "/api/orchestrator/model-routing/resolved"), 200)
    assert hd(body["chains"]["toscanini/annotate"]) == "openrouter/anthropic/claude-sonnet-5.5"

    assert %{"active" => "third-party"} =
             json_response(put(build_conn(), "/api/orchestrator/model-routing/profile", %{"profile" => "third-party"}), 200)
  end

  test "PUT /profile com perfil desconhecido → 422", %{conn: conn} do
    assert %{"error" => _} =
             json_response(put(conn, "/api/orchestrator/model-routing/profile", %{"profile" => "x"}), 422)

    assert json_response(put(build_conn(), "/api/orchestrator/model-routing/profile", %{}), 422)
  end

  test "PUT /cases/*key troca um caso com chave que tem barra", %{conn: conn} do
    body =
      json_response(
        put(conn, "/api/orchestrator/model-routing/cases/scholion/webclip-summary", %{
          "profile" => "third-party",
          "chain" => ["openrouter/openai/gpt-5.1", "openrouter/openai/gpt-5.2"]
        }),
        200
      )

    assert body["case"] == "scholion/webclip-summary"
    assert body["chain"] == ["openrouter/openai/gpt-5.1", "openrouter/openai/gpt-5.2"]

    assert %{"error" => "unknown case" <> _} =
             json_response(
               put(build_conn(), "/api/orchestrator/model-routing/cases/nope", %{
                 "profile" => "third-party",
                 "chain" => ["openrouter/openai/gpt-5.1"]
               }),
               422
             )
  end
end

