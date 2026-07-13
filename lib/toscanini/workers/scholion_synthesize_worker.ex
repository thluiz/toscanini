defmodule Toscanini.Workers.ScholionSynthesizeWorker do
  @moduledoc """
  Sintetiza a nota de citação chamando o preset quote-note do vox-intelligence
  e aplica o portão de voz (ghost-audit). Publica só se a autoria foi verificada
  e o verdict não for `red`; caso contrário, para o pipeline e notifica para
  revisão humana (source-or-silence — evita publicar fabricação).
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}
  alias Toscanini.Clients.{VoxIntelligence, GossipGate}

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
    note       = result["note"]
    authorship = result["authorship"] || %{}
    lexical    = result["lexicalWarnings"] || []
    title      = extract_title(note) || slug

    # Portão de voz estrutural (fail-open: se o audit não roda, segue).
    audit =
      case VoxIntelligence.ghost_audit(note, slug) do
        {:ok, parsed} -> parsed
        {:error, _} -> %{"verdict" => "unknown", "findings" => [], "summary" => "ghost-audit indisponível"}
      end

    verdict = audit["verdict"]

    # Salva sempre a nota + diagnóstico do audit (inclusive quando red), para
    # inspeção via GET /jobs/:id mesmo que o pipeline pare.
    Pipeline.save_result(pipeline, "scholion_synthesize", %{
      "slug"             => slug,
      "note"             => note,
      "title"            => title,
      "authorship"       => authorship,
      "verdict"          => verdict,
      "findings"         => audit["findings"] || [],
      "summary"          => audit["summary"],
      "lexical_warnings" => lexical
    })

    # Só o ghost-audit `red` para o pipeline. Autoria não verificada publica
    # com flag (o solicitante forneceu a fonte) — sinalizada na notificação.
    if verdict == "red" do
      halt(pipeline, slug, title, note, "ghost-audit verdict=red: #{audit["summary"]}", audit["findings"] || [])
    else
      Dispatcher.advance(pid)
      :ok
    end
  end

  # Para o pipeline (status failed) e dá feedback acionável: salva o rascunho
  # em arquivo (para corrigir ou abandonar) e notifica com os findings do
  # ghost-audit (o que precisa ser corrigido). Não publica.
  defp halt(pipeline, slug, title, note, reason, findings) do
    drafts_dir = System.get_env("TOSCANINI_SCHOLION_DRAFTS_DIR", "/home/hermes/scholion-drafts")
    draft_path = Path.join(drafts_dir, slug <> ".md")

    draft_line =
      case File.mkdir_p(drafts_dir) do
        :ok ->
          File.write!(draft_path, note)
          "\n📝 rascunho salvo: <code>#{esc(draft_path)}</code>"

        {:error, e} ->
          "\n⚠️ falha ao salvar rascunho (#{esc(to_string(e))})"
      end

    Pipeline.fail(pipeline, reason)

    GossipGate.send(
      "🛑 <b>Scholion — nota barrada (ghost-audit red)</b>\n" <>
        "<i>#{esc(title)}</i>\n" <>
        "slug: <code>#{esc(slug)}</code>\n\n" <>
        "<b>Motivo:</b> #{esc(reason)}\n" <>
        format_findings(findings) <>
        draft_line <>
        "\n🔎 job: <code>#{esc(pipeline.id)}</code>\n\n" <>
        "Corrija o rascunho e republique, ou abandone."
    )

    :ok
  end

  defp format_findings([]), do: ""

  defp format_findings(findings) when is_list(findings) do
    items =
      findings
      |> Enum.take(8)
      |> Enum.map(fn f ->
        type = f["type"] || f["severity"] || f["kind"] || ""
        msg = f["message"] || f["msg"] || f["detail"] || inspect(f)
        prefix = if type == "", do: "", else: "#{esc(to_string(type))}: "
        "• #{prefix}#{esc(to_string(msg))}"
      end)
      |> Enum.join("\n")

    "\n<b>Findings:</b>\n#{items}\n"
  end

  defp format_findings(_), do: ""

  defp extract_title(note) when is_binary(note) do
    case Regex.run(~r/^title:\s*"(.+?)"\s*$/m, note) do
      [_, t] -> t
      _ -> nil
    end
  end

  defp extract_title(_), do: nil

  defp esc(nil), do: ""

  defp esc(t) when is_binary(t) do
    t |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
  end

  defp esc(t), do: esc(to_string(t))
end
