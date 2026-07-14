defmodule Toscanini.Archive do
  @moduledoc """
  Arquivamento de áudios/transcrições em cold storage (S3), via shell-out ao
  `aws` CLI — mesmo padrão de `curl`/`git`/`yt-dlp` no resto do app. O `aws` faz
  multipart de arquivos grandes automaticamente.

  Desligado por padrão (`TOSCANINI_ARCHIVE_ENABLED != "true"` ou bucket vazio):
  quando `enabled?/0` é `false`, o passo `s3_archive` do pipeline é no-op e o
  fluxo segue normalmente. Config em `config/runtime.exs` sob `:archive`.
  """

  @doc "Config runtime do arquivamento (keyword list)."
  def config, do: Application.get_env(:toscanini, :archive, [])

  @doc "true só quando o arquivamento está ligado E há bucket configurado."
  def enabled? do
    cfg = config()
    cfg[:enabled] == true and to_string(cfg[:bucket]) != ""
  end

  @doc """
  Sobe `local_path` para `s3://<bucket>/<key>` com a `storage_class` dada.
  Retorna `{:ok, key}` ou `{:error, motivo}`.
  """
  def put(local_path, key, storage_class) do
    cfg = config()

    args =
      ["s3", "cp", local_path, "s3://#{cfg[:bucket]}/#{key}",
       "--storage-class", storage_class, "--only-show-errors"] ++ region_args(cfg)

    case System.cmd(bin(cfg), args, stderr_to_stdout: true, env: aws_env(cfg)) do
      {_out, 0}   -> {:ok, key}
      {out, code} -> {:error, "aws s3 cp exit #{code}: #{String.slice(out, 0, 300)}"}
    end
  end

  @doc "Confirma se o objeto já existe no bucket (`head-object` exit 0)."
  def object_exists?(key) do
    cfg = config()
    args = ["s3api", "head-object", "--bucket", to_string(cfg[:bucket]), "--key", key] ++ region_args(cfg)

    case System.cmd(bin(cfg), args, stderr_to_stdout: true, env: aws_env(cfg)) do
      {_out, 0} -> true
      _         -> false
    end
  end

  defp bin(cfg), do: to_string(cfg[:aws_bin] || "aws")

  defp region_args(cfg) do
    case to_string(cfg[:region]) do
      "" -> []
      r  -> ["--region", r]
    end
  end

  defp aws_env(cfg) do
    case to_string(cfg[:profile]) do
      "" -> []
      p  -> [{"AWS_PROFILE", p}]
    end
  end
end
