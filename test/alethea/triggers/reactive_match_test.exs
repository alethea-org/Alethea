defmodule Alethea.Triggers.ReactiveMatchTest do
  @moduledoc """
  Reactive-trigger selection for one burst (#448): what the matcher is
  given, how its failures degrade to "no trigger", and which single match
  is selected against the global threshold.
  """

  use Alethea.DataCase, async: false

  import Alethea.TriggersFixtures
  import Mox

  alias Alethea.AI.TriggerMatcherMock
  alias Alethea.Triggers
  alias Alethea.Triggers.{ReactiveMatch, Trigger}

  setup :verify_on_exit!

  # ----------------------------------------------------------------
  # select_match/2
  # ----------------------------------------------------------------

  describe "select_match/2" do
    test "an empty list selects nothing" do
      assert ReactiveMatch.select_match([], 0.7) == :none
    end

    test "probabilities below the threshold select nothing" do
      assert ReactiveMatch.select_match([{trigger("a"), 0.69}, {trigger("b"), 0.1}], 0.7) ==
               :none
    end

    test "a probability exactly at the threshold is a match" do
      a = trigger("a")
      assert ReactiveMatch.select_match([{a, 0.7}], 0.7) == {:ok, {a, 0.7}}
    end

    test "selects the single highest probability above the threshold" do
      a = trigger("a")
      b = trigger("b")
      c = trigger("c")

      assert ReactiveMatch.select_match([{a, 0.75}, {b, 0.92}, {c, 0.4}], 0.7) ==
               {:ok, {b, 0.92}}
    end

    test "a tie keeps the first candidate in the given order" do
      a = trigger("a")
      b = trigger("b")

      assert ReactiveMatch.select_match([{a, 0.9}, {b, 0.9}], 0.7) == {:ok, {a, 0.9}}
    end
  end

  # ----------------------------------------------------------------
  # find/2 — the matcher boundary
  # ----------------------------------------------------------------

  describe "find/2" do
    setup do
      ctx = fixture_professional_and_patient()
      use_mock_matcher()
      ctx
    end

    test "never calls the matcher when the patient has no eligible reactive trigger", ctx do
      expect(TriggerMatcherMock, :match, 0, fn _, _ -> flunk("matcher must not be called") end)

      assert ReactiveMatch.find(ctx.patient, "texto saneado") == :none
    end

    test "never calls the matcher without a legacy patient" do
      expect(TriggerMatcherMock, :match, 0, fn _, _ -> flunk("matcher must not be called") end)

      assert ReactiveMatch.find(nil, "texto saneado") == :none
    end

    test "sends the burst text and only each trigger's id and sanitized condition", ctx do
      {:ok, trigger} =
        create_reactive(ctx, "Menciona a su hermana (escribe a ana@example.com)")

      test_pid = self()

      expect(TriggerMatcherMock, :match, fn text, candidates ->
        send(test_pid, {:matcher_called, text, candidates})
        {:ok, %{}}
      end)

      ReactiveMatch.find(ctx.patient, "texto saneado de la ráfaga")

      assert_received {:matcher_called, "texto saneado de la ráfaga", [candidate]}
      assert Map.keys(candidate) |> Enum.sort() == [:condition, :id]
      assert candidate.id == trigger.id
      refute candidate.condition =~ "ana@example.com"
      assert candidate.condition =~ "[REDACTED_EMAIL]"
    end

    test "a matcher error degrades to no trigger", ctx do
      {:ok, _} = create_reactive(ctx, "condición")
      expect(TriggerMatcherMock, :match, fn _, _ -> {:error, :unavailable} end)

      assert ReactiveMatch.find(ctx.patient, "texto") == :none
    end

    test "a crashing matcher degrades to no trigger", ctx do
      {:ok, _} = create_reactive(ctx, "condición")
      expect(TriggerMatcherMock, :match, fn _, _ -> raise "matcher exploded" end)

      assert ReactiveMatch.find(ctx.patient, "texto") == :none
    end

    test "a matcher slower than the bound degrades to no trigger", ctx do
      {:ok, _} = create_reactive(ctx, "condición")
      put_timeout(50)

      expect(TriggerMatcherMock, :match, fn _, _ ->
        receive do
          :never_sent -> {:ok, %{}}
        end
      end)

      assert ReactiveMatch.find(ctx.patient, "texto") == :none
    end

    test "probabilities for unknown ids or outside 0..1 are ignored", ctx do
      {:ok, trigger} = create_reactive(ctx, "condición")

      expect(TriggerMatcherMock, :match, fn _, _ ->
        {:ok, %{Ecto.UUID.generate() => 0.99, trigger.id => 1.5}}
      end)

      assert ReactiveMatch.find(ctx.patient, "texto") == :none
    end

    test "returns the selected trigger with its probability", ctx do
      {:ok, trigger} = create_reactive(ctx, "condición")
      expect(TriggerMatcherMock, :match, fn _, _ -> {:ok, %{trigger.id => 0.91}} end)

      assert {:ok, {%Trigger{id: id, decrypted_approved_text: approved}, 0.91}} =
               ReactiveMatch.find(ctx.patient, "texto")

      assert id == trigger.id
      assert approved == "Texto aprobado"
    end
  end

  describe "threshold/0" do
    test "reads the global :trigger_match_threshold" do
      assert ReactiveMatch.threshold() == 0.7
    end
  end

  defp trigger(id), do: %Trigger{id: id, kind: "reactive"}

  defp create_reactive(ctx, condition) do
    Triggers.create_and_approve_reactive_trigger(ctx.professional, ctx.patient.id, %{
      "condition" => condition,
      "instruction" => "Instrucción",
      "approved_text" => "Texto aprobado"
    })
  end

  defp use_mock_matcher do
    original = Application.fetch_env!(:alethea, :trigger_matcher)
    Application.put_env(:alethea, :trigger_matcher, TriggerMatcherMock)
    on_exit(fn -> Application.put_env(:alethea, :trigger_matcher, original) end)
  end

  defp put_timeout(ms) do
    original = Application.fetch_env!(:alethea, :trigger_match_timeout_ms)
    Application.put_env(:alethea, :trigger_match_timeout_ms, ms)
    on_exit(fn -> Application.put_env(:alethea, :trigger_match_timeout_ms, original) end)
  end
end
