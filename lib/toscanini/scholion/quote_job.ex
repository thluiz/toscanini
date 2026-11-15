defmodule Toscanini.Scholion.QuoteJob do
  @moduledoc """
  Creates a `scholion_quote` pipeline (vox-intelligence researches authorship
  and composes the note; the scholion steps write + commit it). Shared by
  `POST /publish/scholion` and the webclip flow, which opens one quote
  pipeline per phrase the author asked for.
  """
  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}

  @doc "Inserts and starts the pipeline. `input` keys: quote (required), presumed_author, context, source_url, from_book. Returns the pipeline id."
  def create(%{"quote" => quote} = input) when is_binary(quote) and quote != "" do
    id = Ecto.UUID.generate()

    input = %{
      "quote" => quote,
      "presumed_author" => input["presumed_author"],
      "context" => input["context"],
      "source_url" => input["source_url"],
      "from_book" => input["from_book"],
      # date from the host's real clock (ISO 8601 + offset), as the skill does.
      "date" => real_date()
    }

    Repo.insert!(%Pipeline{
      id: id,
      content_type: "scholion_quote",
      collector: "publish_quote",
      status: "queued",
      params: "{}",
      results: Jason.encode!(%{"input" => input}),
      # initial marker: advance/1 runs the SUCCESSOR, so the first worker that
      # actually runs is ScholionSynthesizeWorker.
      current_step: "scholion_queued"
    })

    Dispatcher.advance(id)
    id
  end

  defp real_date do
    case System.cmd("date", ["+%Y-%m-%dT%H:%M:%S%:z"]) do
      {out, 0} -> String.trim(out)
      _ -> DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end
end
