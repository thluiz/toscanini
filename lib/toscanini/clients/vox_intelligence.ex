defmodule Toscanini.Clients.VoxIntelligence do
  defp base_url, do: Application.fetch_env!(:toscanini, :base_url)

  def process_podcast(metadata, transcript, timestamps) do
    body = %{
      "transcript" => transcript,
      "timestamps" => timestamps || [],
      "metadata"   => metadata
    }

    case Req.post("#{base_url()}/api/vox-intelligence/presets/podcast/episode",
           json: body,
           receive_timeout: 1_200_000) do
      {:ok, %{status: 200, body: %{"x-parsed" => result}}} ->
        {:ok, result}

      {:ok, %{status: 200, body: %{"ok" => true, "result" => result}}} ->
        {:ok, result}

      {:ok, %{status: s, body: b}} ->
        {:error, "vox-intelligence HTTP #{s}: #{inspect(b)}"}

      {:error, e} ->
        {:error, inspect(e)}
    end
  end

  @doc """
  Primeira fase da anotação automática (preset `podcast/suggest-annotations`,
  modelo barato): analisa o transcript e devolve 8–20 sugestões de pontos dignos
  de anotação. Espelha a skill `suggest-annotations`.

  `episode` é o objeto do episódio (transcript obrigatório; metadata, lang,
  summary, participants, annotations existentes ajudam o contexto).

  Retorna `{:ok, %{"suggestions" => [%{"ts" => ..., "tier" => ...,
  "title" => ..., "description" => ..., "quote" => ...}], "stats" => %{...}}}`.
  """
  def suggest_annotations(episode) when is_map(episode) do
    case Req.post("#{base_url()}/api/vox-intelligence/presets/podcast/suggest-annotations",
           json: %{"episode" => episode},
           receive_timeout: 300_000) do
      {:ok, %{status: 200, body: %{"x-parsed" => result}}} ->
        {:ok, result}

      {:ok, %{status: s, body: b}} ->
        {:error, "vox-intelligence suggest-annotations HTTP #{s}: #{inspect(b)}"}

      {:error, e} ->
        {:error, inspect(e)}
    end
  end

  @doc """
  Segunda fase da anotação automática (preset `podcast/annotate`): dado o
  transcript e uma lista de bookmarks (timestamps), devolve a anotação rica de
  cada um. Espelha a skill `podcast-annotate`.

  `bookmarks` é uma lista de mapas `%{"time" => "HH:MM:SS"}` (com `"note"`
  opcional). Retorna `{:ok, [%{"time" => ..., "title" => ...,
  "description" => ...}]}` (o preset devolve uma lista direta em `x-parsed`).
  """
  def annotate(transcript, bookmarks) when is_binary(transcript) and is_list(bookmarks) do
    case Req.post("#{base_url()}/api/vox-intelligence/presets/podcast/annotate",
           json: %{"transcript" => transcript, "bookmarks" => bookmarks},
           receive_timeout: 600_000) do
      {:ok, %{status: 200, body: %{"x-parsed" => result}}} when is_list(result) ->
        {:ok, result}

      {:ok, %{status: s, body: b}} ->
        {:error, "vox-intelligence annotate HTTP #{s}: #{inspect(b)}"}

      {:error, e} ->
        {:error, inspect(e)}
    end
  end

  @doc """
  Sintetiza uma nota de citação Scholion (add-scholion-quote) a partir de uma
  frase crua + autor presumido. O preset pesquisa autoria na web e compõe a
  nota inteira (frontmatter + corpo), sob source-or-silence.

  Retorna `{:ok, %{"slug" => ..., "note" => ..., "authorship" => %{...},
  "lexicalWarnings" => [...]}}` (o preset devolve o resultado direto, sem
  wrapper `x-parsed`).
  """
  def synthesize_quote(%{quote: _} = input) do
    body = %{
      "quote"          => input.quote,
      "presumedAuthor" => Map.get(input, :presumed_author),
      "context"        => Map.get(input, :context),
      "sourceUrl"      => Map.get(input, :source_url),
      "fromBook"       => Map.get(input, :from_book)
    }

    case Req.post("#{base_url()}/api/vox-intelligence/presets/scholion/quote-note",
           json: body,
           receive_timeout: 300_000) do
      {:ok, %{status: 200, body: %{"slug" => _, "body" => _} = result}} ->
        {:ok, result}

      {:ok, %{status: s, body: b}} ->
        {:error, "vox-intelligence quote-note HTTP #{s}: #{inspect(b)}"}

      {:error, e} ->
        {:error, inspect(e)}
    end
  end

  @doc """
  Roda o ghost-audit estrutural sobre uma nota composta (portão de voz).
  Retorna `{:ok, %{"verdict" => "green"|"yellow"|"red", "findings" => [...],
  "summary" => ...}}`.
  """
  def ghost_audit(content, slug) when is_binary(content) do
    body = %{"content" => content, "slug" => slug}

    case Req.post("#{base_url()}/api/vox-intelligence/presets/scholion/ghost-audit",
           json: body,
           receive_timeout: 300_000) do
      {:ok, %{status: 200, body: %{"x-parsed" => parsed}}} ->
        {:ok, parsed}

      {:ok, %{status: s, body: b}} ->
        {:error, "vox-intelligence ghost-audit HTTP #{s}: #{inspect(b)}"}

      {:error, e} ->
        {:error, inspect(e)}
    end
  end
end
