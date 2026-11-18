defmodule ToscaniniWeb.WebclipControllersTest do
  # ConnCase pulls ToscaniniWeb.verified_routes/0, which this app doesn't
  # define — so the sandbox + ConnTest are set up by hand.
  use Toscanini.DataCase, async: false
  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint ToscaniniWeb.Endpoint

  alias Toscanini.{Repo, Pipeline}

  setup do
    {:ok, conn: build_conn() |> put_req_header("accept", "application/json")}
  end

  describe "POST /api/orchestrator/publish/webclip" do
    test "rejects a missing or non-http url", %{conn: conn} do
      assert json_response(post(conn, "/api/orchestrator/publish/webclip", %{}), 400)

      assert json_response(
               post(conn, "/api/orchestrator/publish/webclip", %{"url" => "ftp://x"}),
               400
             )
    end

    test "queues a scholion_webclip pipeline and dedupes the same url", %{conn: conn} do
      body = %{"url" => "https://example.com/a", "quotes" => ["frase", ""], "comment" => "c"}

      %{"job_id" => id, "status" => "queued"} =
        json_response(post(conn, "/api/orchestrator/publish/webclip", body), 202)

      p = Repo.get!(Pipeline, id)
      assert p.content_type == "scholion_webclip"
      assert p.current_step == "webclip_compose"
      assert Pipeline.get_results(p)["input"]["quotes"] == ["frase"]

      again =
        json_response(
          post(build_conn(), "/api/orchestrator/publish/webclip", %{
            "url" => "https://example.com/a"
          }),
          200
        )

      assert again["job_id"] == id
      assert again["duplicate"] == true
    end
  end

  describe "parked queue" do
    setup do
      id = Ecto.UUID.generate()

      Repo.insert!(%Pipeline{
        id: id,
        content_type: "scholion_webclip",
        collector: "publish_webclip",
        status: "running",
        current_step: "webclip_compose",
        params: Jason.encode!(%{"url" => "https://blocked.com/a"}),
        results:
          Jason.encode!(%{"input" => %{"url" => "https://blocked.com/a", "quotes" => ["q"]}})
      })

      Repo.get!(Pipeline, id)
      |> Pipeline.park("browser", %{"code" => "blocked_domain", "message" => "403"})

      {:ok, id: id}
    end

    test "lists parked pipelines with their reason", %{conn: conn, id: id} do
      %{"count" => 1, "items" => [item]} =
        json_response(get(conn, "/api/orchestrator/parked"), 200)

      assert item["id"] == id
      assert item["reason"] == "browser"
      assert item["code"] == "blocked_domain"
      assert item["url"] == "https://blocked.com/a"
      assert item["quotes"] == ["q"]
      assert item["step"] == "webclip_compose"
    end

    test "resume stores the page text and re-runs compose", %{conn: conn, id: id} do
      resp =
        json_response(
          post(conn, "/api/orchestrator/parked/#{id}/resume", %{"text" => "corpo", "title" => "T"}),
          202
        )

      assert resp["step"] == "webclip_compose"

      p = Repo.get!(Pipeline, id)
      results = Pipeline.get_results(p)
      assert p.status == "running"
      assert results["resume"] == %{"text" => "corpo", "title" => "T"}
      assert results["last_parked"]["reason"] == "browser"
      refute Map.has_key?(results, "parked")

      assert json_response(get(build_conn(), "/api/orchestrator/parked"), 200)["count"] == 0
      assert json_response(post(build_conn(), "/api/orchestrator/parked/#{id}/resume", %{}), 409)
    end

    test "dismiss fails it as manual", %{conn: conn, id: id} do
      assert json_response(
               post(conn, "/api/orchestrator/parked/#{id}/dismiss", %{"reason" => "paywall"}),
               200
             )

      p = Repo.get!(Pipeline, id)
      assert p.status == "failed"
      assert p.error =~ "manual dismiss: paywall"
    end

    test "unknown id is 404", %{conn: conn} do
      assert json_response(post(conn, "/api/orchestrator/parked/nope/dismiss", %{}), 404)
    end
  end

  describe "resume at save (same operation, no new compose)" do
    defp insert_at_save(status) do
      id = Ecto.UUID.generate()

      Repo.insert!(%Pipeline{
        id: id,
        content_type: "scholion_webclip",
        collector: "publish_webclip",
        status: "running",
        current_step: "webclip_save",
        params: Jason.encode!(%{"url" => "https://example.com/s"}),
        results:
          Jason.encode!(%{
            "input" => %{"url" => "https://example.com/s"},
            "webclip_compose" => %{"operation_id" => "op-42", "expires_at" => "2026-11-19T10:00:00Z"}
          })
      })

      p = Repo.get!(Pipeline, id)

      case status do
        "parked" -> Pipeline.park(p, "save_failed", %{"code" => "unreachable", "message" => "timeout"})
        "failed" -> Pipeline.fail(p, "webclipper unreachable on save: timeout")
      end

      id
    end

    defp jobs_for(id) do
      import Ecto.Query
      Repo.all(from j in Oban.Job, where: fragment("json_extract(?, '$.pipeline_id')", j.args) == ^id)
    end

    test "parked save_failed re-runs save with priority 0 in the webclip queue", %{conn: conn} do
      id = insert_at_save("parked")

      assert %{"step" => "webclip_save"} =
               json_response(post(conn, "/api/orchestrator/parked/#{id}/resume", %{}), 202)

      p = Repo.get!(Pipeline, id)
      assert p.status == "running"
      assert p.current_step == "webclip_save"
      assert Pipeline.get_results(p)["webclip_compose"]["operation_id"] == "op-42"

      assert [job] = jobs_for(id)
      assert job.worker == "Toscanini.Workers.WebclipSaveWorker"
      assert job.queue == "webclip"
      assert job.priority == 0
    end

    test "a webclip that failed at save can be resumed", %{conn: conn} do
      id = insert_at_save("failed")

      assert %{"step" => "webclip_save"} =
               json_response(post(conn, "/api/orchestrator/parked/#{id}/resume", %{}), 202)

      p = Repo.get!(Pipeline, id)
      assert p.status == "running"
      assert p.error == nil
    end

    test "resuming with page text recomposes (priority 1)", %{conn: conn} do
      id = insert_at_save("parked")

      assert %{"step" => "webclip_compose"} =
               json_response(
                 post(conn, "/api/orchestrator/parked/#{id}/resume", %{"text" => "corpo"}),
                 202
               )

      assert [job] = jobs_for(id)
      assert job.worker == "Toscanini.Workers.WebclipComposeWorker"
      assert job.priority == 1
    end
  end
end
