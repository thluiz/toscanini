defmodule Toscanini.ContentReposTest do
  use ExUnit.Case, async: true

  alias Toscanini.ContentRepos

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    public = Path.join(dir, "vox-content")
    private = Path.join(dir, "vox-private-content")

    put_json(public, "2026/10/W41/aula-publica")
    put_json(private, "2026/11/W45/Aula-Privada-01")

    %{dirs: [{public, false}, {private, true}], public: public, private: private}
  end

  defp put_json(root, rel) do
    path = Path.join(root, rel <> ".json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{}")
    path
  end

  test "acha no repositório público pelo path exato", %{dirs: dirs, public: public} do
    assert {:ok, json, false} =
             ContentRepos.locate_json("2026/10/W41/aula-publica.md", "aula-publica", dirs)

    assert json == Path.join(public, "2026/10/W41/aula-publica.json")
  end

  test "acha no privado e marca como privado", %{dirs: dirs, private: private} do
    assert {:ok, json, true} =
             ContentRepos.locate_json("2026/11/W45/Aula-Privada-01", "Aula-Privada-01", dirs)

    assert json == Path.join(private, "2026/11/W45/Aula-Privada-01.json")
  end

  test "path com prefixo do site privado (privado/<token>/...) é normalizado", %{dirs: dirs} do
    assert {:ok, _json, true} =
             ContentRepos.locate_json(
               "privado/abc123token/2026/11/W45/Aula-Privada-01/",
               "Aula-Privada-01",
               dirs
             )

    assert ContentRepos.normalize_path("/privado/abc/2026/11/W45/x") == "2026/11/W45/x"
    assert ContentRepos.normalize_path("2026/11/W45/x") == "2026/11/W45/x"
    assert ContentRepos.normalize_path("2026/11/W45/x/") == "2026/11/W45/x"
  end

  test "cai na busca por slug sem diferenciar maiúsculas, em qualquer raiz", %{dirs: dirs} do
    assert {:ok, _json, true} =
             ContentRepos.locate_json("qualquer/lugar/aula-privada-01", "aula-privada-01", dirs)

    assert {:ok, _json, false} = ContentRepos.locate_json("x/AULA-PUBLICA", "AULA-PUBLICA", dirs)
  end

  test "o público ganha quando o mesmo slug existe nos dois", %{
    dirs: [{public, _}, _] = dirs,
    private: private
  } do
    put_json(public, "2026/09/W36/repetida")
    put_json(private, "2026/09/W36/repetida")

    assert {:ok, json, false} = ContentRepos.locate_json("2026/09/W36/repetida", "repetida", dirs)
    assert String.starts_with?(json, public)
  end

  test "episódio inexistente devolve :error", %{dirs: dirs} do
    assert ContentRepos.locate_json("2026/01/W01/nao-existe", "nao-existe", dirs) == :error
  end

  test "sem raiz privada configurada, só o público é consultado", %{public: public} do
    only_public = [{public, false}]

    assert ContentRepos.locate_json("2026/11/W45/Aula-Privada-01", "Aula-Privada-01", only_public) ==
             :error
  end
end
