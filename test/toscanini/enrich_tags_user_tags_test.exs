defmodule Toscanini.EnrichTagsUserTagsTest do
  use ExUnit.Case, async: true

  alias Toscanini.Workers.EnrichTagsWorker

  describe "user_tags/1" do
    test "lê metadata.user_tags" do
      json = %{"metadata" => %{"user_tags" => ["etica", "curso-2026"]}}
      assert EnrichTagsWorker.user_tags(json) == ["etica", "curso-2026"]
    end

    test "ausente ou malformado vira lista vazia" do
      assert EnrichTagsWorker.user_tags(%{"metadata" => %{}}) == []
      assert EnrichTagsWorker.user_tags(%{}) == []
      assert EnrichTagsWorker.user_tags(%{"metadata" => %{"user_tags" => "etica"}}) == []
    end

    test "ignora o que não é texto" do
      assert EnrichTagsWorker.user_tags(%{"metadata" => %{"user_tags" => ["a", 1, nil]}}) == ["a"]
    end
  end

  describe "new_tags/3" do
    test "junta derivadas e do usuário, em slug, sem repetir o que já existe" do
      new = EnrichTagsWorker.new_tags(["etica"], ["Petit Cursos"], ["etica", "Filosofia Política"])
      assert new == ["petit-cursos", "filosofia-politica"]
    end

    test "tag do usuário repetida entre si entra uma vez" do
      assert EnrichTagsWorker.new_tags([], [], ["a", "a", "A"]) == ["a"]
    end

    test "sem tags do usuário o resultado é o de antes" do
      assert EnrichTagsWorker.new_tags(["x"], ["X Y", "x"], []) == ["x-y"]
    end
  end
end
