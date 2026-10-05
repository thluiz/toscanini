defmodule Toscanini.ParticipantAliasesTest do
  use ExUnit.Case, async: true

  alias Toscanini.ParticipantAliases

  @csv """
  variant,canonical
  Thomas Trauman,Thomas Traumann
  Jonathan Cuttrell,Jonathan Cutrell
  Jonathan Cottrell,Jonathan Cutrell
  Atila Iamarino,Átila Iamarino
  "King, Martin",Martin Luther King
  Igual,Igual
  """

  setup do
    {:ok, aliases: ParticipantAliases.parse(@csv)}
  end

  test "parse lê variant->canonical, aceita campo entre aspas e ignora identidade", %{aliases: a} do
    assert a["Thomas Trauman"] == "Thomas Traumann"
    assert a["King, Martin"] == "Martin Luther King"
    refute Map.has_key?(a, "Igual")
    refute Map.has_key?(a, "variant")
  end

  test "parse tolera CRLF" do
    assert ParticipantAliases.parse("variant,canonical\r\nA B,C D\r\n") == %{"A B" => "C D"}
  end

  test "normalize troca participante e slug da tag", %{aliases: a} do
    json = %{
      "participants" => ["Natuza Nery", "Thomas Trauman"],
      "tags" => ["eleicoes-2026", "thomas-trauman", "natuza-nery"]
    }

    {out, renamed} = ParticipantAliases.normalize(json, a)

    assert out["participants"] == ["Natuza Nery", "Thomas Traumann"]
    assert out["tags"] == ["eleicoes-2026", "thomas-traumann", "natuza-nery"]
    assert renamed == [%{"from" => "Thomas Trauman", "to" => "Thomas Traumann"}]
  end

  test "normalize junta variantes que viram o mesmo nome", %{aliases: a} do
    json = %{
      "participants" => ["Jonathan Cuttrell", "Jonathan Cottrell"],
      "tags" => ["jonathan-cuttrell", "jonathan-cottrell", "jonathan-cutrell"]
    }

    {out, _} = ParticipantAliases.normalize(json, a)

    assert out["participants"] == ["Jonathan Cutrell"]
    assert out["tags"] == ["jonathan-cutrell"]
  end

  test "variante que só difere por acento não mexe na tag (slug igual)", %{aliases: a} do
    {out, _} =
      ParticipantAliases.normalize(
        %{"participants" => ["Atila Iamarino"], "tags" => ["atila-iamarino"]},
        a
      )

    assert out["participants"] == ["Átila Iamarino"]
    assert out["tags"] == ["atila-iamarino"]
  end

  test "tabela vazia ou ausente é no-op" do
    json = %{"participants" => ["X"], "tags" => ["x"]}
    assert ParticipantAliases.normalize(json, %{}) == {json, []}
    assert ParticipantAliases.load("/nao/existe.csv") == %{}
  end

  test "normalize tolera episódio sem participants/tags", %{aliases: a} do
    {out, renamed} = ParticipantAliases.normalize(%{"title" => "t"}, a)
    assert out["participants"] == []
    assert out["tags"] == []
    assert renamed == []
  end

  test "slug segue a regra das tags do vox" do
    assert ParticipantAliases.slug("Christopher Kasten-Smith") == "christopher-kastensmith"
    assert ParticipantAliases.slug("Átila Iamarino") == "atila-iamarino"
    assert ParticipantAliases.slug(nil) == ""
  end
end
