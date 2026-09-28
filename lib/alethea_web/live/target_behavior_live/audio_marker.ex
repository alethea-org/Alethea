defmodule AletheaWeb.TargetBehaviorLive.AudioMarker do
  @moduledoc """
  Formats an audio time span for display in the Workbench
  (sdd/audio-evidence-citation-328, GitHub #328, Phase 7, design AD6/AD7).

  Pure module — no LiveView/socket dependency — so the mm:ss formatting
  is unit-testable in isolation and kept out of `review.ex` (AD7).
  """

  @doc """
  Formats `start`/`stop` second offsets as `"min mm:ss – mm:ss"`.

  Seconds are floored before conversion (AD6). The separator is an en
  dash (`–`, U+2013), never an ASCII hyphen. Minutes are unbounded — past
  60 minutes it keeps rendering as `mm:ss` (e.g. `"74:32"`), never adding
  an hours field.
  """
  @spec format_range(number(), number()) :: String.t()
  def format_range(start, stop) do
    "min #{mmss(start)} – #{mmss(stop)}"
  end

  defp mmss(seconds) do
    total_seconds = trunc(seconds)
    minutes = div(total_seconds, 60)
    remaining_seconds = rem(total_seconds, 60)

    "#{pad2(minutes)}:#{pad2(remaining_seconds)}"
  end

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
