defmodule Toscanini.Collectors.YoutubeFeedTest do
  @moduledoc "YoutubeFeed: parse do Atom, resolução de canal e live_status, sem rede nem yt-dlp."
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Toscanini.Collectors.YoutubeFeed

  @channel "UCqBY-VQ2BxHOWnVpuC7swrw"
  @fixture Path.expand("../../support/fixtures/youtube_feed.xml", __DIR__)

  defp xml, do: File.read!(@fixture)

  describe "parse_feed/1" do
    test "extrai videoId/published/title das entries e o nome do canal de <author><name>" do
      assert {:ok, %{episodes: eps, podcast_info: info}} = YoutubeFeed.parse_feed(xml())

      assert [
               %{"uuid" => "vid_new_002", "published" => "2026-11-18T15:00:06+00:00", "title" => "Segundo vídeo — ação & reação"},
               %{"uuid" => "vid_new_001", "published" => "2026-11-11T15:00:00+00:00", "title" => "Primeiro vídeo"},
               %{"uuid" => "vid_old_000"}
             ] = eps

      # o <title> do topo é "Videos"; o <published> do topo (2015) não vira episódio
      assert info.title == "NORMOSE"
      assert info.channel_id == @channel
      refute Enum.any?(eps, &(&1["published"] =~ "2015"))
    end

    test "XML inválido → erro" do
      parent = self()
      capture_log(fn -> send(parent, {:result, YoutubeFeed.parse_feed("<feed><entry>")}) end)
      assert_received {:result, {:error, _}}
    end
  end

  describe "fetch_channel_episodes/2" do
    test "usa o feed UULF e devolve os episódios" do
      parent = self()

      fetch = fn url, _headers ->
        send(parent, {:url, url})
        {:ok, %{status: 200, body: xml(), headers: %{"cache-control" => ["public, max-age=900"]}}}
      end

      assert {:ok, %{episodes: [_, _, _], podcast_info: %{title: "NORMOSE"}, etag: nil, last_modified: nil}} =
               YoutubeFeed.fetch_channel_episodes(@channel, fetch: fetch)

      assert_received {:url, "https://www.youtube.com/feeds/videos.xml?playlist_id=UULFqBY-VQ2BxHOWnVpuC7swrw"}
    end

    test "304 → :not_modified e repassa etag como if-none-match" do
      parent = self()

      fetch = fn _url, headers ->
        send(parent, {:headers, headers})
        {:ok, %{status: 304, headers: %{"etag" => ["\"abc\""]}}}
      end

      assert {:not_modified, %{etag: "\"abc\""}} =
               YoutubeFeed.fetch_channel_episodes(@channel, fetch: fetch, etag: "\"abc\"")

      assert_received {:headers, headers}
      assert {"if-none-match", "\"abc\""} in headers
    end

    test "HTTP != 200 → erro" do
      fetch = fn _, _ -> {:ok, %{status: 404, body: "", headers: %{}}} end
      assert {:error, "youtube feed HTTP 404"} = YoutubeFeed.fetch_channel_episodes(@channel, fetch: fetch)
    end
  end

  describe "resolve_channel_id/2" do
    test "/channel/UC… e UC… puro saem direto, sem yt-dlp" do
      runner = fn _ -> raise "não devia chamar o yt-dlp" end

      assert {:ok, @channel} = YoutubeFeed.resolve_channel_id("https://www.youtube.com/channel/#{@channel}", runner: runner)
      assert {:ok, @channel} = YoutubeFeed.resolve_channel_id("https://www.youtube.com/channel/#{@channel}/videos", runner: runner)
      assert {:ok, @channel} = YoutubeFeed.resolve_channel_id(@channel, runner: runner)
    end

    test "@handle / vídeo / youtu.be passam pelo yt-dlp em modo flat e pegam o primeiro UC…" do
      parent = self()

      runner = fn args ->
        send(parent, {:args, args})
        {"Deprecated Feature: Support for Python version 3.10 has been deprecated\nNA\n#{@channel}\n", 0}
      end

      for url <- ["https://www.youtube.com/@normose", "https://www.youtube.com/watch?v=kSJQooEKRdg",
                  "https://youtu.be/kSJQooEKRdg", "https://www.youtube.com/c/Normose",
                  "https://www.youtube.com/user/normose", "https://www.youtube.com/live/kSJQooEKRdg"] do
        assert {:ok, @channel} = YoutubeFeed.resolve_channel_id(url, runner: runner)
        assert_received {:args, args}
        assert "--flat-playlist" in args
        assert "playlist_channel_id" in args and "channel_id" in args
        assert List.last(args) == url
      end
    end

    test "yt-dlp sem UC… ou com exit != 0 → erro" do
      assert {:error, _} = YoutubeFeed.resolve_channel_id("https://www.youtube.com/@x", runner: fn _ -> {"NA\nNA\n", 0} end)
      assert {:error, _} = YoutubeFeed.resolve_channel_id("https://www.youtube.com/@x", runner: fn _ -> {"ERROR", 1} end)
    end

    test "URL que não é do YouTube → :not_youtube_url" do
      assert {:error, :not_youtube_url} = YoutubeFeed.resolve_channel_id("https://pocketcasts.com/podcast/x")
    end
  end

  describe "upcoming?/2" do
    defp status(out, code \\ 0) do
      parent = self()
      [runner: fn args -> send(parent, {:args, args}); {out, code} end]
    end

    test "is_upcoming / is_live → true" do
      assert YoutubeFeed.upcoming?("v1", status("is_upcoming\n"))
      assert_received {:args, args}
      assert "--ignore-no-formats-error" in args
      assert List.last(args) == "https://www.youtube.com/watch?v=v1"

      assert YoutubeFeed.upcoming?("v1", status("Deprecated Feature: x\nis_live\n"))
    end

    test "not_live / was_live → false" do
      refute YoutubeFeed.upcoming?("v1", status("not_live\n"))
      refute YoutubeFeed.upcoming?("v1", status("was_live\n"))
    end

    test "fail-open: exit != 0, saída inesperada ou timeout → false" do
      log =
        capture_log(fn ->
          refute YoutubeFeed.upcoming?("v1", status("ERROR: Premieres in 3 days", 1))
          refute YoutubeFeed.upcoming?("v1", status("NA\n"))
          refute YoutubeFeed.upcoming?("v1", runner: fn _ -> Process.sleep(:infinity) end, timeout: 50)
        end)

      assert log =~ "live_status"
    end
  end

  describe "helpers" do
    test "youtube_url?/1 e channel_id?/1" do
      assert YoutubeFeed.youtube_url?("https://www.youtube.com/@x")
      assert YoutubeFeed.youtube_url?("https://m.youtube.com/watch?v=x")
      assert YoutubeFeed.youtube_url?("https://youtu.be/x")
      refute YoutubeFeed.youtube_url?("https://pocketcasts.com/podcast/x")
      refute YoutubeFeed.youtube_url?("https://notyoutube.com/x")
      refute YoutubeFeed.youtube_url?(nil)

      assert YoutubeFeed.channel_id?(@channel)
      refute YoutubeFeed.channel_id?("8a3f0e1c-0000-0000-0000-000000000000")
    end

    test "episode_url/1" do
      assert YoutubeFeed.episode_url("abc") == "https://www.youtube.com/watch?v=abc"
    end
  end
end
