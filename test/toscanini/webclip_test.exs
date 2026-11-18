defmodule Toscanini.WebclipTest do
  use ExUnit.Case, async: true

  alias Toscanini.Webclip

  defp op(audit), do: {:ok, %{"operationId" => "op1", "audit" => audit}}

  defp api(code, retryable \\ false),
    do: {:api_error, %{"code" => code, "message" => "m", "retryable" => retryable}}

  describe "classify_compose/3 (response belongs to the request)" do
    defp op_for(url, verdict \\ "green"),
      do: {:ok, %{"operationId" => "op1", "clipping" => %{"url" => url}, "audit" => %{"verdict" => verdict}}}

    test "matching URL falls through to the audit decision" do
      assert Webclip.classify_compose(op_for("https://a.com/x"), false, "https://a.com/x") == :ok

      assert {:park, "audit_red", _} =
               Webclip.classify_compose(op_for("https://a.com/x", "red"), false, "https://a.com/x")
    end

    test "scheme, www., trailing slash and host case don't count as a mismatch" do
      assert Webclip.classify_compose(op_for("http://WWW.a.com/x/"), false, "https://a.com/x") == :ok
    end

    test "another URL retries, then parks without saving" do
      got = op_for("https://devonestes.com/refactoring-for-tests-in-elixir")
      sent = "https://devonestes.com/go-and-elixir-separated-at-birth"

      assert Webclip.classify_compose(got, false, sent) == :retry

      assert {:park, "response_mismatch", %{"message" => msg}} =
               Webclip.classify_compose(got, true, sent)

      assert msg =~ "refactoring-for-tests-in-elixir"
    end

    test "a different query string is another page" do
      assert Webclip.classify_compose(op_for("https://youtube.com/watch?v=b"), false, "https://youtube.com/watch?v=a") ==
               :retry
    end

    test "a response without a clipping URL never passes" do
      assert Webclip.classify_compose({:ok, %{"audit" => %{"verdict" => "green"}}}, false, "https://a.com") ==
               :retry
    end

    test "errors keep their own classification" do
      assert {:park, "browser", _} = Webclip.classify_compose(api("thin_content"), false, "https://a.com")
      assert Webclip.classify_compose({:error, "econnrefused"}, false, "https://a.com") == :retry
    end
  end

  describe "with_draft_slug/2" do
    test "recompose of a red draft asks for the draft's slug" do
      assert Webclip.with_draft_slug(%{"url" => "u"}, %{"slug" => "my-draft"}) ==
               %{"url" => "u", "slug" => "my-draft"}
    end

    test "no draft, no slug" do
      assert Webclip.with_draft_slug(%{"url" => "u"}, nil) == %{"url" => "u"}
      assert Webclip.with_draft_slug(%{"url" => "u"}, %{"slug" => ""}) == %{"url" => "u"}
    end
  end

  test "webclip compose and save run on the serial :webclip queue" do
    assert Toscanini.Workers.WebclipComposeWorker.__opts__()[:queue] == :webclip
    assert Toscanini.Workers.WebclipSaveWorker.__opts__()[:queue] == :webclip

    queues = Application.get_env(:toscanini, Oban)[:queues] || []
    assert Keyword.get(queues, :webclip) == 1
  end

  describe "classify_compose/2" do
    test "green and yellow go on to save" do
      assert Webclip.classify_compose(op(%{"verdict" => "green"}), false) == :ok
      assert Webclip.classify_compose(op(%{"verdict" => "yellow"}), true) == :ok
    end

    test "red parks for local review, with the findings" do
      findings = [%{"rule" => "x", "message" => "y"}]

      assert {:park, "audit_red", %{"findings" => ^findings}} =
               Webclip.classify_compose(op(%{"verdict" => "red", "findings" => findings}), false)
    end

    test "unavailable audit retries, then parks on the last attempt" do
      audit = %{
        "verdict" => "yellow",
        "summary" => "ghost-audit unavailable, proceeding unaudited (fail-open): timeout"
      }

      assert Webclip.classify_compose(op(audit), false) == :retry
      assert {:park, "audit_unavailable", _} = Webclip.classify_compose(op(audit), true)
    end

    test "what the headless fetch can't solve parks for the browser right away" do
      for code <- ~w[blocked_domain consent_wall_unresolved thin_content] do
        assert {:park, "browser", %{"code" => ^code}} = Webclip.classify_compose(api(code), false)
      end
    end

    test "fetch errors retry, then park for the browser" do
      for code <- ~w[fetch_timeout fetch_failed] do
        assert Webclip.classify_compose(api(code, true), false) == :retry
        assert {:park, "browser", _} = Webclip.classify_compose(api(code, true), true)
      end
    end

    test "transient service errors retry, then fail" do
      assert Webclip.classify_compose(api("summary_failed", true), false) == :retry
      assert {:fail, _} = Webclip.classify_compose(api("summary_failed", true), true)
    end

    test "auth and validation errors fail at once" do
      assert {:fail, _} = Webclip.classify_compose(api("authentication_error"), false)
      assert {:fail, _} = Webclip.classify_compose(api("validation_error"), false)
    end

    test "transport errors retry, then fail" do
      assert Webclip.classify_compose({:error, "econnrefused"}, false) == :retry
      assert {:fail, _} = Webclip.classify_compose({:error, "econnrefused"}, true)
    end
  end

  describe "classify_save/2" do
    test "ok and already-saved advance" do
      assert Webclip.classify_save({:ok, %{"slug" => "s"}}, false) == :ok
      assert Webclip.classify_save(api("operation_already_saved"), false) == :ok
    end

    test "expired operation goes back to compose" do
      assert Webclip.classify_save(api("operation_not_found"), false) == :recompose
    end

    test "slug conflict and red park" do
      assert {:park, "slug_conflict", _} = Webclip.classify_save(api("slug_conflict"), false)
      assert {:park, "audit_red", _} = Webclip.classify_save(api("audit_red"), false)
    end

    test "retryable errors retry while attempts remain, then park save_failed" do
      assert Webclip.classify_save(api("internal_error", true), false) == :retry

      assert {:park, "save_failed", %{"code" => "internal_error"}} =
               Webclip.classify_save(api("internal_error", true), true)

      assert {:fail, _} = Webclip.classify_save(api("forbidden"), false)
    end

    test "transport failure (timeout, 502) retries, then parks save_failed" do
      assert Webclip.classify_save({:error, "webclipper HTTP 502: \"\""}, false) == :retry

      assert {:park, "save_failed", %{"code" => "unreachable", "message" => "timeout"}} =
               Webclip.classify_save({:error, "timeout"}, true)
    end
  end

  describe "resume_step/4" do
    @composed %{"webclip_compose" => %{"operation_id" => "op-1"}}

    test "parked save_failed with a known operation retries the save" do
      results = Map.put(@composed, "parked", %{"reason" => "save_failed", "step" => "webclip_save"})
      assert Webclip.resume_step("parked", "webclip_save", results, %{}) == "webclip_save"
    end

    test "failed at save (before 0.2.53) retries the save" do
      assert Webclip.resume_step("failed", "webclip_save", @composed, %{}) == "webclip_save"
    end

    test "new page text or related notes need a fresh compose" do
      results = Map.put(@composed, "parked", %{"reason" => "save_failed"})

      assert Webclip.resume_step("parked", "webclip_save", results, %{"text" => "t"}) ==
               "webclip_compose"

      assert Webclip.resume_step("parked", "webclip_save", results, %{
               "related_notes" => [%{"slug" => "s"}]
             }) == "webclip_compose"
    end

    test "other park reasons, even at save, recompose" do
      for reason <- ~w[slug_conflict audit_red browser response_mismatch] do
        results = Map.put(@composed, "parked", %{"reason" => reason, "step" => "webclip_save"})
        assert Webclip.resume_step("parked", "webclip_save", results, %{}) == "webclip_compose"
      end
    end

    test "without an operation id it recomposes" do
      results = %{"parked" => %{"reason" => "save_failed"}}
      assert Webclip.resume_step("parked", "webclip_save", results, %{}) == "webclip_compose"
      assert Webclip.resume_step("failed", "webclip_save", %{}, %{}) == "webclip_compose"
    end

    test "failed at compose recomposes" do
      assert Webclip.resume_step("failed", "webclip_compose", @composed, %{}) == "webclip_compose"
    end
  end

  describe "priority in the webclip queue" do
    test "save runs before queued composes" do
      assert Toscanini.Pipeline.Dispatcher.priority(:webclip_save) <
               Toscanini.Pipeline.Dispatcher.priority(:webclip_compose)
    end
  end

  describe "ObanNotifier.last_attempt?/1" do
    test "only the last attempt notifies" do
      refute Toscanini.ObanNotifier.last_attempt?(%{attempt: 1, max_attempts: 3})
      refute Toscanini.ObanNotifier.last_attempt?(%{attempt: 2, max_attempts: 3})
      assert Toscanini.ObanNotifier.last_attempt?(%{attempt: 3, max_attempts: 3})
    end
  end

  describe "compose_body/2" do
    test "URL mode by default" do
      assert Webclip.compose_body(%{"url" => "https://a.com/x"}) == %{"url" => "https://a.com/x"}
    end

    test "text mode when resumed with page text" do
      body =
        Webclip.compose_body(%{"url" => "https://www.nytimes.com/x"}, %{
          "text" => "corpo",
          "title" => "T"
        })

      assert body == %{
               "text" => "corpo",
               "title" => "T",
               "url" => "https://www.nytimes.com/x",
               "domain" => "nytimes-com"
             }
    end

    test "text mode without a title falls back to the URL" do
      body =
        Webclip.compose_body(%{"url" => "https://a.com/x"}, %{"text" => "corpo", "title" => " "})

      assert body["title"] == "https://a.com/x"
    end

    test "related notes go along in either mode" do
      notes = [%{"slug" => "s", "title" => "t"}]

      assert Webclip.compose_body(%{"url" => "https://a.com"}, %{"related_notes" => notes})[
               "relatedNotes"
             ] == notes
    end
  end

  test "domain_slug/1" do
    assert Webclip.domain_slug("https://www.Example.co.uk/a") == "example-co-uk"
    assert Webclip.domain_slug("http://blog.x.com") == "blog-x-com"
  end

  test "normalize_quotes/1" do
    assert Webclip.normalize_quotes(nil) == []
    assert Webclip.normalize_quotes(" uma ") == ["uma"]
    assert Webclip.normalize_quotes(["a", "", 3, " b "]) == ["a", "b"]
  end
end
