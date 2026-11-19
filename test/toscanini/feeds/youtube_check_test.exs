defmodule Toscanini.Feeds.YoutubeCheckTest do
  @moduledoc """
  Feeds com source youtube: inferência de source no subscribe, watermark inicial e
  check/2 (job com collector youtube, parada na estreia, dedup). fetch/runner injetados.
  """
  use Toscanini.DataCase, async: false

  alias Toscanini.{Feeds, FeedSubscription, Pipeline}

  @channel "UCqBY-VQ2BxHOWnVpuC7swrw"
  @fixture Path.expand("../../support/fixtures/youtube_feed.xml", __DIR__)

  defp fetch, do: fn _url, _h -> {:ok, %{status: 200, body: File.read!(@fixture), headers: %{}}} end

  defp runner(upcoming) do
    fn args ->
      cond do
        "--flat-playlist" in args -> {"NA\n#{@channel}\n", 0}
        Enum.any?(upcoming, &String.ends_with?(List.last(args), "v=" <> &1)) -> {"is_upcoming\n", 0}
        true -> {"not_live\n", 0}
      end
    end
  end

  defp opts(upcoming \\ []), do: [fetch: fetch(), runner: runner(upcoming)]

  defp urls do
    Pipeline |> Repo.all() |> Enum.map(&Jason.decode!(&1.params)["url"]) |> Enum.sort()
  end

  describe "infer_source/1" do
    test "URL do YouTube e feed_ref UC… → youtube; Pocket Casts e source explícito ficam" do
      assert %{source: "youtube"} = Feeds.infer_source(%{url: "https://www.youtube.com/@normose"})
      assert %{source: "youtube"} = Feeds.infer_source(%{url: "https://youtu.be/abc"})
      assert %{source: "youtube"} = Feeds.infer_source(%{feed_ref: @channel})
      refute Map.has_key?(Feeds.infer_source(%{url: "https://pocketcasts.com/podcast/x/uuid"}), :source)
      refute Map.has_key?(Feeds.infer_source(%{feed_ref: "8a3f0e1c-1111-2222-3333-444455556666"}), :source)
      assert %{source: "rss"} = Feeds.infer_source(%{source: "rss", url: "https://www.youtube.com/@x"})
    end
  end

  describe "subscribe/2 youtube" do
    test "@handle → feed_ref UC…, título do canal, watermark no vídeo mais recente, sem backfill" do
      assert {:ok, sub} = Feeds.subscribe(%{"url" => "https://www.youtube.com/@normose"}, opts())

      assert sub.source == "youtube"
      assert sub.feed_ref == @channel
      assert sub.title == "NORMOSE"
      assert sub.last_published_at == ~U[2026-11-18 15:00:06Z]
      assert sub.last_episode_uuid == "vid_new_002"
      # 3 vídeos < amostra mínima de 4 → hot sempre ligado
      assert FeedSubscription.check_days(sub) == []
      assert urls() == []
    end
  end

  describe "check/2 youtube" do
    defp sub_at(watermark) do
      {:ok, sub} = Feeds.subscribe(%{"feed_ref" => @channel, "check_days" => []}, opts())
      {:ok, sub} = sub |> FeedSubscription.changeset(%{last_published_at: watermark}) |> Repo.update()
      sub
    end

    test "um vídeo novo → job avulso com collector youtube e URL watch?v=" do
      sub = sub_at(~U[2026-11-12 00:00:00Z])

      assert {:ok, {:submitted, 1}} = Feeds.check(sub, opts())

      assert [p] = Repo.all(Pipeline)
      assert p.collector == "youtube"
      assert p.content_type == "podcast"
      assert %{"url" => "https://www.youtube.com/watch?v=vid_new_002", "auto_annotate" => false} = Jason.decode!(p.params)

      updated = Repo.get!(FeedSubscription, sub.id)
      assert updated.last_published_at == ~U[2026-11-18 15:00:06Z]
      assert updated.last_episode_uuid == "vid_new_002"
    end

    test "estreia depois de um vídeo pronto → submete só o anterior; watermark para nele" do
      sub = sub_at(~U[2026-11-05 00:00:00Z])

      assert {:ok, {:submitted, 1}} = Feeds.check(sub, opts(["vid_new_002"]))
      assert urls() == ["https://www.youtube.com/watch?v=vid_new_001"]

      updated = Repo.get!(FeedSubscription, sub.id)
      assert updated.last_published_at == ~U[2026-11-11 15:00:00Z]
      assert updated.last_episode_uuid == "vid_new_001"
    end

    test "estreia como primeiro vídeo novo → segura ela e os seguintes; watermark parado" do
      sub = sub_at(~U[2026-11-05 00:00:00Z])

      assert {:ok, :no_change} = Feeds.check(sub, opts(["vid_new_001"]))
      assert urls() == []

      updated = Repo.get!(FeedSubscription, sub.id)
      assert updated.last_published_at == ~U[2026-11-05 00:00:00Z]
      assert updated.last_checked_at != nil
    end

    test "vídeo já submetido à mão (pipeline não-falho com a mesma URL) não duplica" do
      sub = sub_at(~U[2026-11-12 00:00:00Z])

      Repo.insert!(%Pipeline{
        id: Ecto.UUID.generate(),
        content_type: "podcast",
        collector: "youtube",
        status: "running",
        params: Jason.encode!(%{"url" => "https://www.youtube.com/watch?v=vid_new_002"})
      })

      assert {:ok, {:submitted, 1}} = Feeds.check(sub, opts())
      assert Repo.aggregate(Pipeline, :count) == 1
    end
  end
end
