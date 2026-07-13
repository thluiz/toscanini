defmodule Toscanini.Workers.ScholionSynthesizeWorker do
  @moduledoc """
  Compõe a nota de citação: chama o preset quote-note do vox-intelligence (que
  devolve os CAMPOS estruturados), serializa o markdown Scholion via
  `Toscanini.Scholion.Note`, e aplica o portão de voz (ghost-audit).

  - verdict != red → segue e publica.
  - verdict == red → re-serializa com `draft: true` e segue mesmo assim: a nota
    fica versionada em content/notes/, mas o Hugo não a publica (draft).
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}
  alias Toscanini.Clients.VoxIntelligence
  alias Toscanini.Scholion.Note

  @impl Oban.Worker
  def perform(%{args: %{"pipeline_id" => pid}}) do
    pipeline = Repo.get!(Pipeline, pid)
    input = Pipeline.get_results(pipeline)["input"]

    synth_input = %{
      quote: input["quote"],
      presumed_author: input["presumed_author"],
      context: input["context"]
    }

    case VoxIntelligence.synthesize_quote(synth_input) do
      {:ok, fields} ->
        handle_result(pipeline, pid, fields, input["date"])

      {:error, reason} ->
        # Transitório (LLM/rede) — deixa o Oban retentar.
        {:error, reason}
    end
  end

  defp handle_result(pipeline, pid, fields, date) do
    slug       = fields["slug"]
    title      = fields["title"] || slug
    authorship = fields["authorship"] || %{}
    lexical    = fields["lexicalWarnings"] || []

    # Serializa (sem draft) e roda o portão de voz sobre a nota.
    note = Note.to_markdown(fields, date)

    audit =
      case VoxIntelligence.ghost_audit(note, slug) do
        {:ok, parsed} -> parsed
        {:error, _} -> %{"verdict" => "unknown", "findings" => [], "summary" => "ghost-audit indisponível"}
      end

    verdict = audit["verdict"]
    is_draft = verdict == "red"

    # Red → re-serializa determinísticamente com draft: true (nota fica fora do ar).
    final_note = if is_draft, do: Note.to_markdown(fields, date, draft: true), else: note

    Pipeline.save_result(pipeline, "scholion_synthesize", %{
      "slug"             => slug,
      "note"             => final_note,
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
end
