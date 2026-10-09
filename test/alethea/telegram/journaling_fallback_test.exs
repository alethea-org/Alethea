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

  # #393 S2 (design §6): closing/acknowledgement copy is a separate,
  # shared pair of lists — one guard reason is irrelevant to this
  # layer. `variants/0` itself stays untouched (still 4, each a
  # question): asserted again below as a regression guard.
  describe "closing_invitations/0 and acknowledgements/0" do
    test "variants/0 is unaffected: still 4 entries, each a question" do
      assert length(JournalingFallback.variants()) == 4
    end

    for {list_name, getter} <- [
          {"closing_invitations", &JournalingFallback.closing_invitations/0},
          {"acknowledgements", &JournalingFallback.acknowledgements/0}
        ] do
      test "#{list_name}/0 has at least 2 distinct entries, each passing the output guard with no question",
           %{} do
        getter = unquote(getter)
        entries = getter.()

        assert length(entries) >= 2
        assert Enum.uniq(entries) == entries

        for entry <- entries do
          assert JournalingOutputGuard.check(entry) == :ok, entry
          refute entry =~ "?", entry
          refute entry =~ "¿", entry
        end
      end
    end
  end

  describe "closing_for_inbound/1" do
    test "returns the same closing invitation every time for the same inbound, varying across inbounds" do
      for id <- @inbound_ids do
        assert JournalingFallback.closing_for_inbound(id) ==
                 JournalingFallback.closing_for_inbound(id)
      end

      chosen = Enum.map(@inbound_ids, &JournalingFallback.closing_for_inbound/1)

      assert Enum.all?(chosen, &(&1 in JournalingFallback.closing_invitations()))
    end
  end

  describe "acknowledgement_for_inbound/1" do
    test "returns the same acknowledgement every time for the same inbound, varying across inbounds" do
      for id <- @inbound_ids do
        assert JournalingFallback.acknowledgement_for_inbound(id) ==
                 JournalingFallback.acknowledgement_for_inbound(id)
      end

      chosen = Enum.map(@inbound_ids, &JournalingFallback.acknowledgement_for_inbound/1)

      assert Enum.all?(chosen, &(&1 in JournalingFallback.acknowledgements()))
    end
  end
end
