defmodule Toscanini.Git do
  @moduledoc """
  Helper compartilhado de commit/pull/push, parametrizado por diretório de
  repositório. A autenticação (deploy key) é resolvida pelo remote do próprio
  clone via `~/.ssh/config` (host aliases) — nenhuma chave vive no código.

  Extraído de `Workers.GitCommitWorker` para ser reusado pelo pipeline Scholion.
  """

  @doc """
  Faz stage dos `files`, commita com `message`, sincroniza (`pull --rebase`) e
  dá push, tudo em `dir`.

  Trata "nothing to commit" como sucesso (idempotência em reprocessos).

  Retorna `{:ok, commit_output}` ou `{:error, reason}`.
  """
  def commit_and_push(dir, files, message) when is_list(files) do
    with :ok <- add(dir, files),
         {:ok, commit_output} <- commit(dir, message),
         :ok <- pull_rebase(dir),
         :ok <- push(dir) do
      {:ok, commit_output}
    end
  end

  defp add(dir, files) do
    case System.cmd("git", ["add" | files], cd: dir, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, "git add failed (#{status}): #{out}"}
    end
  end

  defp commit(dir, message) do
    {output, status} =
      System.cmd("git", ["commit", "-m", message], cd: dir, stderr_to_stdout: true)

    nothing_to_commit = String.contains?(output, "nothing to commit")

    cond do
      status == 0 -> {:ok, String.trim(output)}
      nothing_to_commit -> {:ok, String.trim(output)}
      true -> {:error, "git commit failed (#{status}): #{output}"}
    end
  end

  defp pull_rebase(dir) do
    case System.cmd("git", ["pull", "--rebase"], cd: dir, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, "git pull --rebase failed (#{status}): #{out}"}
    end
  end

  defp push(dir) do
    case System.cmd("git", ["push"], cd: dir, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, "git push failed (#{status}): #{out}"}
    end
  end
end
