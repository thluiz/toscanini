defmodule Mix.Tasks.Toscanini.RestoreSubscriptions do
  @shortdoc "Recria as assinaturas de feed a partir do SUBSCRIPTIONS.md"

  @moduledoc """
  Restaura a tabela `feed_subscriptions` a partir do `SUBSCRIPTIONS.md`.

      mix toscanini.restore_subscriptions [--file CAMINHO] [--dry-run]

  Pré-requisito: o banco já migrado (`mix ecto.migrate`). Assinaturas que já
  existem (mesmo `source` + `feed_ref`) são puladas. Cada uma passa por
  `Toscanini.Feeds.subscribe/2`, que busca o feed no PocketCasts para gravar o
  watermark (episódio mais recente, sem reprocessar o catálogo), então precisa
  de rede.

  Sobe só o Repo e o cliente HTTP, não a aplicação inteira: não inicia Oban nem
  o endpoint, então não dispara varredura de feeds nem disputa a porta com o
  serviço. Termina com status 1 se alguma assinatura falhar.
  """
  use Mix.Task

  alias Toscanini.Feeds.Backup

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [file: :string, dry_run: :boolean])

    file = opts[:file] || Backup.path() || "SUBSCRIPTIONS.md"

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Toscanini.Repo.start_link(pool_size: 2)

    content =
      case File.read(file) do
        {:ok, c} -> c
        {:error, reason} -> Mix.raise("não consegui ler #{file}: #{:file.format_error(reason)}")
      end

    rows =
      case Backup.parse(content) do
        {:ok, [_ | _] = rows} -> rows
        {:ok, []} -> Mix.raise("#{file} não tem nenhuma linha de assinatura")
        {:error, {line, reason}} -> Mix.raise("#{file}, linha #{line}: #{inspect(reason)}")
      end

    dry_run? = Keyword.get(opts, :dry_run, false)
    Mix.shell().info("#{length(rows)} assinatura(s) em #{file}#{if dry_run?, do: " (dry-run)", else: ""}")

    %{restored: restored, skipped: skipped, failed: failed} = Backup.restore(rows, dry_run: dry_run?)

    Mix.shell().info("restauradas: #{restored} | já existiam: #{skipped} | falharam: #{length(failed)}")

    Enum.each(failed, fn {feed_ref, reason} ->
      Mix.shell().error("  falhou #{feed_ref}: #{inspect(reason)}")
    end)

    unless dry_run? or failed != [] do
      Mix.shell().info("Para atualizar o arquivo com o estado do banco, faça qualquer alteração de assinatura ou rode Toscanini.Feeds.Backup.sync/0.")
    end

    if failed != [], do: exit({:shutdown, 1})
  end
end
