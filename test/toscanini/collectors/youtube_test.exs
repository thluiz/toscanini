defmodule Toscanini.Collectors.YoutubeTest do
  @moduledoc """
  Testes unitários para o collector de YouTube. Cobre as funções puras
  (build_meta/2 e write_json/2) com fixtures que mimetizam a saída do
  `yt-dlp --print '%(.{...})j'`. Não chama yt-dlp nem rede.
  """

  use ExUnit.Case, async: true

  alias Toscanini.Collectors.Youtube

  @sample_info %{
    "id" => "kSJQooEKRdg",
    "title" => "O Mito da Elegância: Como a França vende uma Mentira para o mundo?",
    "channel" => "NORMOSE",
    "channel_id" => "UCqBY-VQ2BxHOWnVpuC7swrw",
    "channel_url" => "https://www.youtube.com/channel/UCqBY-VQ2BxHOWnVpuC7swrw",
    "uploader" => "NORMOSE",
    "timestamp" => 1_775_057_647,
    "upload_date" => "20260401",
    "duration" => 2735,
    "description" => "Neste vídeo, o Normose investiga...",
    "categories" => ["Entertainment"],
    "tags" => [],
    "webpage_url" => "https://www.youtube.com/watch?v=kSJQooEKRdg",
    "thumbnail" => "https://i.ytimg.com/vi/kSJQooEKRdg/maxresdefault.jpg",
    "language" => "pt"
  }

  @source_url "https://www.youtube.com/watch?v=kSJQooEKRdg"

  describe "build_meta/2 — happy path" do
    setup do
      {:ok, meta} = Youtube.build_meta(@sample_info, @source_url)
      %{meta: meta}
    end

    test "preserves the title verbatim", %{meta: m} do
      assert m.title == @sample_info["title"]
    end

    test "produces an ascii kebab slug from PT title with diacritics", %{meta: m} do
      assert m.slug == "o-mito-da-elegancia-como-a-franca-vende-uma-mentira-para-o-mundo"
    end

    test "maps channel to podcast and uploader to author", %{meta: m} do
      assert m.podcast == "NORMOSE"
      assert m.author == "NORMOSE"
    end

    test "uses video id as uuid and channel_id as podcast_uuid", %{meta: m} do
      assert m.uuid == "kSJQooEKRdg"
      assert m.podcast_uuid == "UCqBY-VQ2BxHOWnVpuC7swrw"
    end

    test "podcast_show_type is hardcoded to video", %{meta: m} do
      assert m.podcast_show_type == "video"
    end

    test "duration_secs is integer-truncated", %{meta: m} do
      assert m.duration_secs == 2735
    end

    test "published is ISO8601 UTC from timestamp", %{meta: m} do
      assert m.published == "2026-04-01T15:34:07Z"
    end

    test "categories are joined with newlines", %{meta: m} do
      assert m.podcast_categories == "Entertainment"
    end

    test "passes through description, thumbnail, language, source_url", %{meta: m} do
      assert m.description == "Neste vídeo, o Normose investiga..."
      assert m.thumbnail == "https://i.ytimg.com/vi/kSJQooEKRdg/maxresdefault.jpg"
      assert m.language == "pt"
      assert m.source_url == @source_url
    end
  end

  describe "build_meta/2 — fallbacks and edge cases" do
    test "falls back to upload_date when timestamp is missing" do
      info = Map.delete(@sample_info, "timestamp")
      {:ok, m} = Youtube.build_meta(info, @source_url)
      assert m.published == "2026-04-01T00:00:00Z"
    end

    test "published is nil when both timestamp and upload_date missing" do
      info = @sample_info |> Map.delete("timestamp") |> Map.delete("upload_date")
      {:ok, m} = Youtube.build_meta(info, @source_url)
      assert is_nil(m.published)
    end

    test "podcast falls back to uploader when channel is missing" do
      info = @sample_info |> Map.delete("channel") |> Map.put("uploader", "Some Uploader")
      {:ok, m} = Youtube.build_meta(info, @source_url)
      assert m.podcast == "Some Uploader"
    end

    test "duration_secs is nil for non-numeric input" do
      info = Map.put(@sample_info, "duration", nil)
      {:ok, m} = Youtube.build_meta(info, @source_url)
      assert is_nil(m.duration_secs)
    end

    test "categories joined with newline when multiple" do
      info = Map.put(@sample_info, "categories", ["Education", "Science"])
      {:ok, m} = Youtube.build_meta(info, @source_url)
      assert m.podcast_categories == "Education\nScience"
    end

    test "podcast_categories is nil when categories list is empty" do
      info = Map.put(@sample_info, "categories", [])
      {:ok, m} = Youtube.build_meta(info, @source_url)
      assert is_nil(m.podcast_categories)
    end

    test "title with newlines is collapsed to single line" do
      info = Map.put(@sample_info, "title", "Line 1\r\nLine 2")
      {:ok, m} = Youtube.build_meta(info, @source_url)
      assert m.title == "Line 1 Line 2"
    end

    test "slug truncates to 80 chars" do
      long_title = String.duplicate("a", 200)
      info = Map.put(@sample_info, "title", long_title)
      {:ok, m} = Youtube.build_meta(info, @source_url)
      assert String.length(m.slug) == 80
    end

    test "returns error tuple when title contains only non-ascii/punctuation" do
      info = Map.put(@sample_info, "title", "!!!???")
      assert {:error, "slug vazio" <> _} = Youtube.build_meta(info, @source_url)
    end
  end

  describe "write_json/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "youtube_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {:ok, meta} = Youtube.build_meta(@sample_info, @source_url)
      %{outdir: tmp, meta: meta}
    end

    test "writes <slug>.json with version + metadata + transcript:nil on first run", %{outdir: dir, meta: meta} do
      {:ok, json_path} = Youtube.write_json(dir, meta)
      assert json_path == Path.join(dir, "#{meta.slug}.json")

      data = json_path |> File.read!() |> Jason.decode!()
      assert data["version"] == 1
      assert is_nil(data["transcript"])

      m = data["metadata"]
      assert m["source"] == "youtube"
      assert m["podcast_type"] == "video"
      assert m["title"] == meta.title
      assert m["uuid"] == "kSJQooEKRdg"
      assert m["podcast_uuid"] == "UCqBY-VQ2BxHOWnVpuC7swrw"
      assert m["podcast_categories"] == "Entertainment"
      assert m["duration"] == "00:45:35"
      assert m["thumbnail"] == "https://i.ytimg.com/vi/kSJQooEKRdg/maxresdefault.jpg"
    end

    test "sets description and lang at top level on first run", %{outdir: dir, meta: meta} do
      {:ok, json_path} = Youtube.write_json(dir, meta)
      data = json_path |> File.read!() |> Jason.decode!()
      assert data["description"] == "Neste vídeo, o Normose investiga..."
      assert data["lang"] == "pt"
    end

    test "preserves existing top-level fields like summary/transcript on re-run", %{outdir: dir, meta: meta} do
      json_path = Path.join(dir, "#{meta.slug}.json")

      File.write!(json_path, Jason.encode!(%{
        "version" => 1,
        "transcript" => "transcrição do whisper",
        "summary" => "resumo gerado pelo summarize",
        "tags" => ["tag1", "tag2"],
        "metadata" => %{"old_field" => "preservado"}
      }))

      {:ok, _} = Youtube.write_json(dir, meta)
      data = json_path |> File.read!() |> Jason.decode!()

      assert data["transcript"] == "transcrição do whisper"
      assert data["summary"] == "resumo gerado pelo summarize"
      assert data["tags"] == ["tag1", "tag2"]
      assert data["metadata"]["old_field"] == "preservado"
      assert data["metadata"]["source"] == "youtube"
    end

    test "does not overwrite description/lang when they already exist", %{outdir: dir, meta: meta} do
      json_path = Path.join(dir, "#{meta.slug}.json")

      File.write!(json_path, Jason.encode!(%{
        "version" => 1,
        "description" => "descrição editada manualmente",
        "lang" => "en"
      }))

      {:ok, _} = Youtube.write_json(dir, meta)
      data = json_path |> File.read!() |> Jason.decode!()

      assert data["description"] == "descrição editada manualmente"
      assert data["lang"] == "en"
    end

    test "nil metadata fields do not clobber existing ones", %{outdir: dir} do
      info = @sample_info |> Map.put("thumbnail", nil) |> Map.put("language", nil)
      {:ok, meta} = Youtube.build_meta(info, @source_url)

      json_path = Path.join(dir, "#{meta.slug}.json")
      File.write!(json_path, Jason.encode!(%{
        "version" => 1,
        "metadata" => %{"thumbnail" => "https://existing/thumb.jpg"}
      }))

      {:ok, _} = Youtube.write_json(dir, meta)
      data = json_path |> File.read!() |> Jason.decode!()

      assert data["metadata"]["thumbnail"] == "https://existing/thumb.jpg"
    end
  end
end
