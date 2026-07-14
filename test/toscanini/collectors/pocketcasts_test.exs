defmodule Toscanini.Collectors.PocketcastsTest do
  @moduledoc "Testes das funções puras do collector PocketCasts (sem rede)."
  use ExUnit.Case, async: true

  alias Toscanini.Collectors.Pocketcasts

  @podcast "11c1c780-0000-0000-0000-000000000001"
  @episode "22c2c780-0000-0000-0000-000000000002"

  describe "podcast_uuid_from_url/1" do
    test "extrai o primeiro UUID de uma URL podcast/episode" do
      url = "https://pocketcasts.com/podcast/#{@podcast}/episode/#{@episode}"
      assert {:ok, @podcast} == Pocketcasts.podcast_uuid_from_url(url)
    end

    test "erro quando não há UUID na URL" do
      assert {:error, _} = Pocketcasts.podcast_uuid_from_url("https://pca.st/discover")
    end
  end

  describe "episode_url/2" do
    test "monta URL submetível com ambos os UUIDs no path" do
      url = Pocketcasts.episode_url(@podcast, @episode)
      assert url == "https://pocketcasts.com/podcast/#{@podcast}/episode/#{@episode}"
      # roundtrip: a URL montada resolve de volta ao podcast_uuid
      assert {:ok, @podcast} == Pocketcasts.podcast_uuid_from_url(url)
    end
  end
end
