defmodule Toscanini.Workers.ScholionSynthesizeWorker do
  @moduledoc """
  Sintetiza a nota de citação chamando o preset quote-note do vox-intelligence
  e aplica o portão de voz (ghost-audit).

  - verdict != red → segue e publica normalmente.
  - verdict == red → marca a nota com `draft: true` e segue mesmo assim: a nota
    fica versionada em `content/notes/<slug>.md` (corrigível, não perdida), mas
    o Hugo não a publica (build sem `--buildDrafts`). O que precisa ser
    corrigido vai nos findings da notificação.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}
  alias Toscanini.Clients.VoxIntelligence

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    pipeline = Repo.get!(Pipeline, pid)
    input = Pipeline.get_results(pipeline)["input"]

    synth_input = %{
      quote: input["quote"],
      presumed_author: input["presumed_author"],
      context: input["context"],
      date: input["date"]
    }

    case VoxIntelligence.synthesize_quote(synth_input) do
      {:ok, result} ->
        handle_result(pipeline, pid, result)

      {:error, reason} ->
        # Transitório (LLM/rede) — deixa o Oban retentar.
        {:error, reason}
    end
  end

  defp handle_result(pipeline, pid, result) do
    slug       = result["slug"]
    note0      = result["note"]
    authorship = result["authorship"] || %{}
    lexical    = result["lexicalWarnings"] || []
    title      = extract_title(note0) || slug

    # Portão de voz estrutural (fail-open: se o audit não roda, segue).
    audit =
      case VoxIntelligence.ghost_audit(note0, slug) do
        {:ok, parsed} -> parsed
        {:error, _} -> %{"verdict" => "unknown", "findings" => [], "summary" => "ghost-audit indisponível"}
      end

    verdict = audit["verdict"]
    is_draft = verdict == "red"

    # Red → marca `draft: true` no frontmatter. A nota é commitada mesmo assim
    # (versionada e corrigível), mas fica fora do ar até removerem o flag.
    note = if is_draft, do: mark_as_draft(note0), else: note0

    Pipeline.save_result(pipeline, "scholion_synthesize", %{
      "slug"             => slug,
      "note"             => note,
      "title"            => title,
      "authorship"       => authorship,
      "verdict"          => verdict,
      "draft"            => is_draft,
      "findings"         => audit["findings"] || [],
      "summary"          => audit["summary"],
      "lexical_warnings" => lexical
    })

    Dispatcher.advance(pid)
    :ok
  end

  # Insere `draft: true` como primeiro campo do frontmatter YAML.
  defp mark_as_draft(note) when is_binary(note) do
    if String.starts_with?(note, "---") do
      String.replace(note, ~r/\A---\r?\n/, "---\ndraft: true\n", global: false)
    else
      "---\ndraft: true\n---\n\n" <> note
    end
  end

  defp extract_title(note) when is_binary(note) do
    case Regex.run(~r/^title:\s*"(.+?)"\s*$/m, note) do
      [_, t] -> t
      _ -> nil
    end
  end

  defp extract_title(_), do: nil
end
