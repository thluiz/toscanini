defmodule Toscanini.AudioDurationTest do
  use ExUnit.Case, async: true

  alias Toscanini.AudioDuration

  describe "reconcile/2" do
    test "measured duration wins over wrong metadata (Filosofia Pop #224)" do
      assert AudioDuration.reconcile(202_740, {:ok, 3380}) == 3380
    end

    test "falls back to metadata when ffprobe fails" do
      assert AudioDuration.reconcile(3723, :error) == 3723
      assert AudioDuration.reconcile(3723.9, :error) == 3723
    end

    test "0 when there is neither" do
      assert AudioDuration.reconcile(nil, :error) == 0
    end
  end

  describe "divergent?/2" do
    test "flags the h:m vs m:s confusion" do
      assert AudioDuration.divergent?(202_740, 3380)
    end

    test "tolerates small differences (ads, rounding)" do
      refute AudioDuration.divergent?(3723, 3700)
    end

    test "missing metadata is not divergence" do
      refute AudioDuration.divergent?(nil, 3380)
      refute AudioDuration.divergent?(0, 3380)
    end
  end

  describe "parse/1" do
    test "rounds ffprobe output" do
      assert AudioDuration.parse("3379.748571\n") == {:ok, 3380}
    end

    test "rejects garbage and N/A" do
      assert AudioDuration.parse("N/A\n") == :error
      assert AudioDuration.parse("") == :error
    end
  end

  describe "probe/1" do
    test ":error for missing file or nil" do
      assert AudioDuration.probe("/nonexistent/x.mp3") == :error
      assert AudioDuration.probe(nil) == :error
    end

    @tag :tmp_dir
    test "measures a real file", %{tmp_dir: dir} do
      ffmpeg = System.find_executable("ffmpeg")

      if ffmpeg && System.find_executable("ffprobe") do
        path = Path.join(dir, "tone.mp3")
        {_, 0} =
          System.cmd(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=duration=7",
                              "-q:a", "9", path], stderr_to_stdout: true)

        assert {:ok, 7} = AudioDuration.probe(path)
      end
    end
  end
end

