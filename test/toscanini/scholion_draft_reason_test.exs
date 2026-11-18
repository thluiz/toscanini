defmodule Toscanini.ScholionDraftReasonTest do
  use ExUnit.Case, async: true

  alias Toscanini.Workers.ScholionSynthesizeWorker, as: W

  test "red audit is a draft, whatever the authorship" do
    assert W.draft_reason("red", %{"verified" => true}) == "audit_red"
    assert W.draft_reason("red", %{"verified" => false}) == "audit_red"
  end

  test "no verifiable source for the attribution is a draft (2026-11-17 tweet quotes)" do
    assert W.draft_reason("green", %{"verified" => false, "notes" => "sem fonte"}) == "unverified"
    assert W.draft_reason("yellow", %{"verified" => false}) == "unverified"
  end

  test "verified and not red publishes" do
    assert W.draft_reason("green", %{"verified" => true}) == nil
    assert W.draft_reason("yellow", %{"verified" => true}) == nil
    assert W.draft_reason("unknown", %{}) == nil
  end
end
