defmodule Toscanini.VoxPocketcastJsonRendererTest do
  @moduledoc """
  Tests for the Toscanini → Vox-Hugo markdown renderer.

  Uses two real episode JSON fixtures (one PT, one EN) captured from
  `E:\\vox-content` with the transcript field stripped to keep fixtures
  small. Tests focus on:

    * the overall shape of the rendered markdown (frontmatter → title →
      sections),
    * the presence of the editorial sections we want to keep,
    * the **absence** of the metadata sections that were moved to the
      Vox-Hugo `episode-footer` partial in v0.2.2,
    * the absence of the legacy hardcoded JSON pointer link.

  The renderer is a pure function, so the test case runs `async: true`.
  """

  use ExUnit.Case, async: true

  alias Toscanini.VoxPocketcastJsonRenderer

  @fixtures_dir Path.expand("../fixtures/renderer", __DIR__)

  defp load_fixture(name) do
    @fixtures_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  describe "render/2 with a PT episode (t12exxnov-republica)" do
    setup do
      json = load_fixture("t12exxnov-republica.json")
      output = VoxPocketcastJsonRenderer.render(json)
      %{json: json, output: output}
    end

    test "starts with a YAML frontmatter block", %{output: out} do
      assert String.starts_with?(out, "---\n")
    end

    test "frontmatter contains expected fields", %{output: out} do
      assert out =~ "title: T12ExxNov - República"
      assert out =~ "lang: pt"
      assert out =~ "podcast: Fronteiras da Ciência"
      assert out =~ "uuid: 13286f3e-f6c5-4875-a87a-9cd8334b3b78"
      assert out =~ "published: '2021-11-15T14:00:00Z'"
    end

    test "renders title as H1 heading", %{output: out} do
      assert out =~ "# T12ExxNov - República"
    end

    test "renders the PT summary section", %{output: out} do
      assert out =~ "## Resumo"
      assert out =~ "Neste episódio especial do Fronteiras da Ciência"
    end

    test "renders the PT timeline section with bullet entries", %{output: out} do
      assert out =~ "## Linha do Tempo"
      assert out =~ ~r/^- \*\*\d{2}:\d{2}(:\d{2})?\*\* —/m
    end

    test "renders the PT recommendations section with title-cased category", %{output: out} do
      assert out =~ "## Indicações"
      assert out =~ "### Leis"
      assert out =~ "Emenda Constitucional 95 de 2017"
    end

    test "does NOT emit metadata sections (now rendered by Hugo footer)", %{output: out} do
      refute out =~ "## Dados do Episódio"
      refute out =~ "## Dados do Podcast"
      refute out =~ "## Episode Info"
      refute out =~ "## Podcast Info"
    end

    test "does NOT emit the legacy hardcoded JSON pointer link", %{output: out} do
      refute out =~ "Dados adicionais e transcrição"
      refute out =~ "Additional data and transcript"
    end

    test "does NOT emit a transcript section (renderer strips it)", %{output: out} do
      refute out =~ "## Transcrição"
      refute out =~ "## Transcript"
    end
  end

  describe "render/2 with an EN episode (friday-refill-give-tomorrowyou-advice)" do
    setup do
      json = load_fixture("friday-refill-give-tomorrowyou-advice-from-today.json")
      output = VoxPocketcastJsonRenderer.render(json)
      %{json: json, output: output}
    end

    test "starts with a YAML frontmatter block", %{output: out} do
      assert String.starts_with?(out, "---\n")
    end

    test "frontmatter contains expected fields", %{output: out} do
      assert out =~ "lang: en"
      assert out =~ "podcast: Developer Tea"
      assert out =~ "uuid: 2d699972-c079-4637-8c66-e91ff97e3e3c"
      assert out =~ "Friday Refill"
    end

    test "frontmatter includes the single participant", %{output: out} do
      assert out =~ "Jonathan Patrell"
    end

    test "renders title as H1 heading", %{output: out} do
      assert out =~ ~r/^# .*Friday Refill/m
    end

    test "renders the EN summary section", %{output: out} do
      assert out =~ "## Summary"
      assert out =~ "The episode opens by acknowledging"
    end

    test "renders the EN timeline section", %{output: out} do
      assert out =~ "## Topic Timeline"
      assert out =~ ~r/^- \*\*\d{2}:\d{2}(:\d{2})?\*\* —/m
    end

    test "renders the EN recommendations section with title-cased category", %{output: out} do
      assert out =~ "## Recommendations"
      assert out =~ "### Practices"
      assert out =~ "Journaling advice for your future self"
    end

    test "does NOT emit metadata sections (now rendered by Hugo footer)", %{output: out} do
      refute out =~ "## Episode Info"
      refute out =~ "## Podcast Info"
      refute out =~ "## Dados do Episódio"
      refute out =~ "## Dados do Podcast"
    end

    test "does NOT emit the legacy hardcoded JSON pointer link", %{output: out} do
      refute out =~ "Additional data and transcript"
      refute out =~ "Dados adicionais e transcrição"
    end
  end

  describe "render/2 with minimal input" do
    test "returns a string even when most fields are missing" do
      minimal = %{
        "title" => "Bare Minimum",
        "lang" => "en",
        "summary" => "Tiny.",
        "metadata" => %{}
      }

      output = VoxPocketcastJsonRenderer.render(minimal)

      assert is_binary(output)
      assert output =~ "title: Bare Minimum"
      assert output =~ "# Bare Minimum"
      assert output =~ "## Summary"
      assert output =~ "Tiny."
    end

    test "ignores the :slug option (forward-compat after v0.2.2)" do
      minimal = %{
        "title" => "x",
        "lang" => "pt",
        "summary" => "y",
        "metadata" => %{}
      }

      assert VoxPocketcastJsonRenderer.render(minimal, slug: "whatever") ==
               VoxPocketcastJsonRenderer.render(minimal, [])
    end
  end
end

