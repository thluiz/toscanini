defmodule ToscaniniWeb.ScholionPublishController do
  use ToscaniniWeb, :controller
  alias Toscanini.{Repo, Pipeline, Pipeline.Dispatcher}

  # Publica uma nota de citação no Scholion (paridade com a skill
  # add-scholion-quote): vox-intelligence pesquisa a autoria e compõe a nota,
  # e o pipeline scholion escreve + commita no repo de conteúdo.
  def create(conn, %{"quote" => quote} = params) when is_binary(quote) and quote != "" do
    id = Ecto.UUID.generate()

    input = %{
      "quote"          => quote,
      "presumed_author" => params["presumed_author"],
      "context"        => params["context"],
      "source_url"     => params["source_url"],
      "from_book"      => params["from_book"],
      # date com o relógio real do host (ISO 8601 + offset), como a skill faz.
      "date"           => real_date()
    }

    initial_results = Jason.encode!(%{"input" => input})

    Repo.insert!(%Pipeline{
      id:           id,
      content_type: "scholion_quote",
      collector:    "publish_quote",
      status:       "queued",
      params:       "{}",
      results:      initial_results,
      # marcador inicial: advance/1 roda o SUCESSOR, então o primeiro worker a
      # efetivamente rodar é o ScholionSynthesizeWorker (sucessor deste).
      current_step: "scholion_queued"
    })

    Dispatcher.advance(id)

    conn |> put_status(202) |> json(%{job_id: id, status: "queued"})
  end

  def create(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required field: quote"})
  end

  defp real_date do
    case System.cmd("date", ["+%Y-%m-%dT%H:%M:%S%:z"]) do
      {out, 0} -> String.trim(out)
      _ -> DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end
end
