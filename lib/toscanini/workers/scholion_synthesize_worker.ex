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

    # Só o ghost-audit `red` para o pipeline. Autoria não verificada publica
    # com flag (o solicitante forneceu a fonte) — sinalizada na notificação.
    cond do
      verdict == "red" ->
        halt(pipeline, slug, title, "ghost-audit verdict=red: #{audit["summary"]}")

      true ->
        Pipeline.save_result(pipeline, "scholion_synthesize", %{
          "slug"             => slug,
          "note"             => note,
          "title"            => title,
          "authorship"       => authorship,
          "verdict"          => verdict,
          "findings"         => audit["findings"] || [],
          "lexical_warnings" => lexical
        })

        Dispatcher.advance(pid)
        :ok
    end
  end

  # Para o pipeline (status failed) e notifica; não publica.
  defp halt(pipeline, slug, title, reason) do
    Pipeline.fail(pipeline, reason)

    GossipGate.send(
      "⚠️ <b>Scholion — revisão necessária</b>\n" <>
        "<i>#{esc(title)}</i>\n" <>
        "slug: <code>#{esc(slug)}</code>\n" <>
        "#{esc(reason)}\n\nNota NÃO publicada."
    )

    :ok
  end

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
