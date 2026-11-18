defmodule Toscanini.Feeds.Backup do
  @moduledoc """
  Espelho em Markdown da configuração das assinaturas de feed (`SUBSCRIPTIONS.md`,
  na raiz do repositório) e a restauração a partir dele.

  O banco (`data/orchestrator.db`) não tem backup: quase tudo nele é transacional
  (`oban_jobs`), exceto `feed_subscriptions`, que é configuração. Este módulo
  reescreve o arquivo sempre que uma assinatura é criada, alterada ou removida
  (`Feeds.subscribe/2`, `Feeds.update_subscription/2`, `Feeds.delete_subscription/1`),
  e `restore/2` (via `mix toscanini.restore_subscriptions`) recria as assinaturas
  a partir dele.

  O arquivo não guarda o watermark (`last_published_at`, `last_episode_uuid`,
  `last_checked_at`, etag): muda a cada checagem e geraria ruído. Na restauração
  cada assinatura passa por `Feeds.subscribe/2`, que grava um watermark novo
  (episódio mais recente do feed) sem processar o catálogo (backfill off).

  Escrever o arquivo nunca derruba a operação que o chamou: falha só vira log.
  O commit no git é manual.
  """
  import Ecto.Query
  require Logger

  alias Toscanini.{Repo, Feeds, FeedSubscription}

  @default_path "SUBSCRIPTIONS.md"
  @columns 8

  @doc """
  Caminho do arquivo (relativo ao WorkingDirectory do serviço, que é a raiz do
  repo). `nil` desliga a escrita; o ambiente de teste faz isso.
  """
  def path, do: Application.get_env(:toscanini, :subscriptions_md_path, @default_path)

  # ---- Escrita --------------------------------------------------------------

  @doc """
  Reescreve o arquivo com o estado atual do banco. Devolve `:ok`, `:unchanged`,
  `:disabled` ou `{:error, exception}`. Não grava se o conteúdo for idêntico.
  """
  def sync do
    case path() do
      nil -> :disabled
      p -> write(p, render(list()))
    end
  rescue
    e ->
      Logger.warning("[Feeds.Backup] sync falhou: #{Exception.message(e)}")
      {:error, e}
  end

  defp list do
    Repo.all(from s in FeedSubscription, order_by: [asc: fragment("lower(?)", s.title), asc: s.feed_ref])
  end

  defp write(p, content) do
    if File.read(p) == {:ok, content} do
      :unchanged
    else
      tmp = p <> ".tmp"
      File.write!(tmp, content)
      File.rename!(tmp, p)
      :ok
    end
  rescue
    e ->
      Logger.warning("[Feeds.Backup] não consegui gravar #{p}: #{Exception.message(e)}")
      {:error, e}
  end

  # ---- Formato --------------------------------------------------------------

  @doc "Renderiza a lista de assinaturas como o conteúdo do `SUBSCRIPTIONS.md`."
  def render(subs) do
    header = """
    # Inscrições de feeds

    Backup da configuração da tabela `feed_subscriptions`, reescrito automaticamente quando uma assinatura é criada, alterada ou removida. Não editar à mão: a próxima escrita sobrescreve.

    Não inclui a marca do último episódio visto (`last_episode_uuid`, `last_published_at`, `last_checked_at`), que muda a cada checagem. Na restauração, cada assinatura ganha uma marca nova (o episódio mais recente do feed), sem reprocessar o catálogo.

    Restaurar: `mix ecto.migrate` num banco vazio e depois `mix toscanini.restore_subscriptions` (opções `--file` e `--dry-run`).

    | Título | source | feed_ref | active | auto_annotate | check_days | hot (min) | idle (min) |
    |---|---|---|---|---|---|---|---|
    """

    rows =
      Enum.map(subs, fn s ->
        "| #{esc(s.title)} | #{s.source} | `#{s.feed_ref}` | #{yn(s.active)} | #{yn(s.auto_annotate)} | " <>
          "#{days(s)} | #{s.hot_interval_min} | #{s.idle_interval_min} |\n"
      end)

    header <> Enum.join(rows)
  end

  defp yn(true), do: "sim"
  defp yn(_), do: "não"

  defp days(sub) do
    case FeedSubscription.check_days(sub) do
      [] -> "sempre"
      list -> Enum.join(list, ",")
    end
  end

  defp esc(nil), do: ""
  defp esc(s), do: s |> to_string() |> String.replace("|", "\\|") |> String.replace(~r/\s*\n\s*/, " ")

  # ---- Leitura --------------------------------------------------------------

  @doc """
  Lê as linhas da tabela de um `SUBSCRIPTIONS.md`. Devolve `{:ok, [attrs]}` com os
  campos prontos para `Feeds.subscribe/2`, ou `{:error, {numero_da_linha, motivo}}`.
  """
  def parse(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> data_row?(line) end)
    |> Enum.reduce_while({:ok, []}, fn {line, n}, {:ok, acc} ->
      case parse_row(line) do
        {:ok, attrs} -> {:cont, {:ok, [attrs | acc]}}
        {:error, reason} -> {:halt, {:error, {n, reason}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp data_row?("| Título" <> _), do: false
  defp data_row?("|---" <> _), do: false
  defp data_row?("|" <> _), do: true
  defp data_row?(_), do: false

  defp parse_row(line) do
    cells =
      line
      |> String.trim()
      |> String.trim_leading("|")
      |> String.trim_trailing("|")
      |> String.split(~r/(?<!\\)\|/)
      |> Enum.map(&(&1 |> String.trim() |> String.replace("\\|", "|")))

    with true <- length(cells) == @columns || {:error, {:expected_columns, @columns, length(cells)}},
         [title, source, feed_ref, active, auto, days, hot, idle] = cells,
         feed_ref = String.trim(feed_ref, "`"),
         true <- feed_ref != "" || {:error, :empty_feed_ref},
         {:ok, active} <- yn_parse(active),
         {:ok, auto} <- yn_parse(auto),
         {:ok, hot} <- int_parse(hot),
         {:ok, idle} <- int_parse(idle) do
      {:ok,
       %{
         title: if(title == "", do: nil, else: title),
         source: source,
         feed_ref: feed_ref,
         active: active,
         auto_annotate: auto,
         # lista explícita (mesmo []): impede a inferência de janela no subscribe
         check_days: days_parse(days),
         hot_interval_min: hot,
         idle_interval_min: idle
       }}
    else
      {:error, _} = e -> e
    end
  end

  defp yn_parse("sim"), do: {:ok, true}
  defp yn_parse("não"), do: {:ok, false}
  defp yn_parse(other), do: {:error, {:bad_boolean, other}}

  defp int_parse(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, {:bad_integer, str}}
    end
  end

  defp days_parse("sempre"), do: []
  defp days_parse(str), do: str |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  # ---- Restauração ----------------------------------------------------------

  @doc """
  Recria as assinaturas de `rows` (saída de `parse/1`). Pula as que já existem
  (mesmo `source` + `feed_ref`). Não reescreve o arquivo durante a restauração.

  Opções: `:dry_run` (só conta), `:subscribe` (função de 2 aridades, para teste).
  Devolve `%{restored: n, skipped: n, failed: [{feed_ref, motivo}]}`.
  """
  def restore(rows, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    subscribe = Keyword.get(opts, :subscribe, &Feeds.subscribe/2)

    Enum.reduce(rows, %{restored: 0, skipped: 0, failed: []}, fn attrs, acc ->
      cond do
        Repo.get_by(FeedSubscription, source: attrs.source, feed_ref: attrs.feed_ref) ->
          %{acc | skipped: acc.skipped + 1}

        dry_run? ->
          %{acc | restored: acc.restored + 1}

        true ->
          case subscribe.(attrs, sync: false) do
            {:ok, _sub} -> %{acc | restored: acc.restored + 1}
            {:error, reason} -> %{acc | failed: acc.failed ++ [{attrs.feed_ref, reason}]}
          end
      end
    end)
  end
end
