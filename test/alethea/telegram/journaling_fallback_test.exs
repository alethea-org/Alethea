defmodule Alethea.Telegram.JournalingFallbackTest do
  use ExUnit.Case, async: true

  alias Alethea.AI.JournalingOutputGuard
  alias Alethea.Telegram.JournalingFallback

  @inbound_ids for n <- 1..40,
                   do: "00000000-0000-4000-8000-#{String.pad_leading("#{n}", 12, "0")}"

  describe "variants/0" do
    test "offers several distinct variants" do
      variants = JournalingFallback.variants()

      assert length(variants) >= 3
      assert Enum.uniq(variants) == variants
    end

    test "every variant passes the output guard it stands in for" do
      for variant <- JournalingFallback.variants() do
        assert JournalingOutputGuard.check(variant) == :ok, variant
      end
    end

    test "every variant is short and asks exactly one question, last" do
      for variant <- JournalingFallback.variants() do
        assert String.length(variant) <= 160, variant
        assert String.ends_with?(variant, "?"), variant
        assert variant |> String.graphemes() |> Enum.count(&(&1 == "?")) == 1, variant
      end
    end
  end

  describe "for_inbound/1" do
    test "returns the same variant every time for the same inbound" do
      for id <- @inbound_ids do
        assert JournalingFallback.for_inbound(id) == JournalingFallback.for_inbound(id)
      end
    end

    test "varies across inbounds and only ever returns a known variant" do
      chosen = Enum.map(@inbound_ids, &JournalingFallback.for_inbound/1)

      assert length(Enum.uniq(chosen)) > 1
      assert Enum.all?(chosen, &(&1 in JournalingFallback.variants()))
    end
  end
end
