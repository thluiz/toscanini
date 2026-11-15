defmodule Toscanini.WebclipTest do
  use ExUnit.Case, async: true

  alias Toscanini.Webclip

  defp op(audit), do: {:ok, %{"operationId" => "op1", "audit" => audit}}
  defp api(code, retryable \\ false), do: {:api_error, %{"code" => code, "message" => "m", "retryable" => retryable}}

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
      audit = %{"verdict" => "yellow", "summary" => "ghost-audit unavailable, proceeding unaudited (fail-open): timeout"}
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

    test "retryable errors retry while attempts remain" do
      assert Webclip.classify_save(api("internal_error", true), false) == :retry
      assert {:fail, _} = Webclip.classify_save(api("internal_error", true), true)
      assert {:fail, _} = Webclip.classify_save(api("forbidden"), false)
    end
  end

  describe "compose_body/2" do
    test "URL mode by default" do
      assert Webclip.compose_body(%{"url" => "https://a.com/x"}) == %{"url" => "https://a.com/x"}
    end

    test "text mode when resumed with page text" do
      body = Webclip.compose_body(%{"url" => "https://www.nytimes.com/x"}, %{"text" => "corpo", "title" => "T"})

      assert body == %{"text" => "corpo", "title" => "T", "url" => "https://www.nytimes.com/x", "domain" => "nytimes-com"}
    end

    test "text mode without a title falls back to the URL" do
      body = Webclip.compose_body(%{"url" => "https://a.com/x"}, %{"text" => "corpo", "title" => " "})
      assert body["title"] == "https://a.com/x"
    end

    test "related notes go along in either mode" do
      notes = [%{"slug" => "s", "title" => "t"}]
      assert Webclip.compose_body(%{"url" => "https://a.com"}, %{"related_notes" => notes})["relatedNotes"] == notes
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
