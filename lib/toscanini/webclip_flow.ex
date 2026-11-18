defmodule Toscanini.WebclipFlow do
  @moduledoc """
  Side effects shared by the webclip workers: park or fail the pipeline and
  tell the author on Telegram. The decisions themselves live in
  `Toscanini.Webclip` (pure).
  """
  alias Toscanini.Pipeline
  alias Toscanini.Clients.GossipGate

  @reason_label %{
    "browser" => "🅿️ <b>Webclip na fila do Chrome</b> — o servidor não conseguiu ler a página",
    "audit_red" => "🛑 <b>Webclip barrado (ghost-audit red)</b> — aguardando revisão local",
    "audit_red_draft" =>
      "🛑 <b>Webclip barrado (ghost-audit red)</b> — guardado como rascunho (não publicado), aguardando revisão local",
    "audit_unavailable" =>
      "🅿️ <b>Webclip parado</b> — ghost-audit indisponível em todas as tentativas",
    "slug_conflict" => "🅿️ <b>Webclip parado</b> — já existe nota com esse slug",
    "response_mismatch" =>
      "🅿️ <b>Webclip parado</b> — o webclipper respondeu com o clipping de outra URL em todas as tentativas",
    "save_failed" =>
      "🅿️ <b>Webclip composto, save falhou</b> — retomar tenta o save da mesma operação (sem novo compose)"
  }

  def park(pipeline, reason, detail) do
    Pipeline.park(pipeline, reason, detail)

    url = input_url(pipeline)
    label_key = if reason == "audit_red" and detail["draft_note"], do: "audit_red_draft", else: reason
    label = Map.get(@reason_label, label_key, "🅿️ <b>Webclip parado</b> (#{escape(reason)})")

    draft =
      cond do
        detail["draft_note"] -> "\n📝 rascunho: <code>#{escape(detail["draft_note"])}</code>"
        detail["draft_error"] -> "\n⚠️ rascunho NÃO gravado: #{escape(detail["draft_error"])}"
        true -> ""
      end

    draft =
      if detail["expires_at"],
        do: draft <> "\n⏳ operação vale até <code>#{escape(detail["expires_at"])}</code>",
        else: draft

    why =
      case {detail["code"], detail["message"]} do
        {nil, nil} ->
          ""

        {code, msg} ->
          "\n#{escape(to_string(code || reason))}: #{escape(String.slice(to_string(msg), 0, 200))}"
      end

    GossipGate.send(
      "#{label}\n#{escape(url)}#{draft}#{why}#{format_findings(detail["findings"])}\n🔎 job: <code>#{escape(pipeline.id)}</code>"
    )

    :ok
  end

  def fail(pipeline, message) do
    Pipeline.fail(pipeline, message)

    GossipGate.send(
      "❌ <b>Webclip falhou</b>\n#{escape(input_url(pipeline))}\n#{escape(String.slice(message, 0, 300))}\n" <>
        "🔎 job: <code>#{escape(pipeline.id)}</code>"
    )

    :ok
  end

  def input_url(pipeline), do: get_in(Pipeline.get_results(pipeline), ["input", "url"]) || ""

  def format_findings(findings) when is_list(findings) and findings != [] do
    items =
      findings
      |> Enum.take(6)
      |> Enum.map(fn f ->
        rule = f["rule"] || f["type"] || ""
        msg = f["message"] || f["excerpt"] || f["suggestion"] || ""
        "• #{escape(to_string(rule))}: #{escape(String.slice(to_string(msg), 0, 160))}"
      end)
      |> Enum.join("\n")

    "\n<b>Findings:</b>\n#{items}"
  end

  def format_findings(_), do: ""

  def escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
