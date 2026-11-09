defmodule Toscanini.PrivateSiteTest do
  use ExUnit.Case, async: true

  alias Toscanini.PrivateSite

  @guid "3f9a1c2e-0b7d-4e1a-9c55-aa11bb22cc33"

  test "monta a URL do episódio com o guid e barra final" do
    assert PrivateSite.url("2026/11/W45/aula-01.md", "https://vox.thluiz.com", @guid) ==
             "https://vox.thluiz.com/privado/#{@guid}/2026/11/W45/aula-01/"
  end

  test "aceita path sem .md e base com barra final" do
    assert PrivateSite.url("2026/11/W45/aula-01", "https://vox.thluiz.com/", @guid) ==
             "https://vox.thluiz.com/privado/#{@guid}/2026/11/W45/aula-01/"
  end

  test "sem guid ou sem path não há link" do
    assert PrivateSite.url("2026/11/W45/aula-01.md", "https://vox.thluiz.com", nil) == nil
    assert PrivateSite.url("2026/11/W45/aula-01.md", "https://vox.thluiz.com", "") == nil
    assert PrivateSite.url(nil, "https://vox.thluiz.com", @guid) == nil
  end

  test "guid/0 lê TOSCANINI_VOX_PRIVATE_GUID e ignora valor vazio" do
    old = System.get_env("TOSCANINI_VOX_PRIVATE_GUID")

    try do
      System.put_env("TOSCANINI_VOX_PRIVATE_GUID", @guid)
      assert PrivateSite.guid() == @guid

      System.put_env("TOSCANINI_VOX_PRIVATE_GUID", "")
      assert PrivateSite.guid() == nil

      System.delete_env("TOSCANINI_VOX_PRIVATE_GUID")
      assert PrivateSite.guid() == nil
    after
      if old,
        do: System.put_env("TOSCANINI_VOX_PRIVATE_GUID", old),
        else: System.delete_env("TOSCANINI_VOX_PRIVATE_GUID")
    end
  end
end
