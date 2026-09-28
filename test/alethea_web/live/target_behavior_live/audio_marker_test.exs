defmodule AletheaWeb.TargetBehaviorLive.AudioMarkerTest do
  @moduledoc """
  Unit tests for `AletheaWeb.TargetBehaviorLive.AudioMarker.format_range/2`
  (sdd/audio-evidence-citation-328, GitHub #328, Phase 7, design AD6/AD7).

  AD6 locks the format: `"min mm:ss – mm:ss"` with an en dash separator,
  seconds floored, and minutes always rendered as `mm:ss` even past 60
  minutes (no hours field).
  """
  use ExUnit.Case, async: true

  alias AletheaWeb.TargetBehaviorLive.AudioMarker

  describe "format_range/2 (R3, AD6)" do
    test "formats start/stop pairs as floored mm:ss joined by an en dash (table-driven)" do
      cases = [
        {0, 59.9, "min 00:00 – 00:59"},
        {860, 910, "min 14:20 – 15:10"},
        {4472, 4500, "min 74:32 – 75:00"}
      ]

      for {start, stop, expected} <- cases do
        assert AudioMarker.format_range(start, stop) == expected
      end
    end

    test "uses an en dash (U+2013), not an ASCII hyphen, as the separator" do
      result = AudioMarker.format_range(0, 1)
      assert result =~ "–"
      refute result =~ " - "
    end
  end
end
