defmodule ToscaniniWeb.ScholionPublishController do
  use ToscaniniWeb, :controller
  alias Toscanini.Scholion.QuoteJob

  # Publica uma nota de citação no Scholion (paridade com a skill
  # add-scholion-quote): vox-intelligence pesquisa a autoria e compõe a nota,
  # e o pipeline scholion escreve + commita no repo de conteúdo.
  def create(conn, %{"quote" => quote} = params) when is_binary(quote) and quote != "" do
    id = QuoteJob.create(params)
    conn |> put_status(202) |> json(%{job_id: id, status: "queued"})
  end

  def create(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required field: quote"})
  end
end
