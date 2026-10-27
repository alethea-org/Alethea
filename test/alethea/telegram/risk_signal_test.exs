defmodule Alethea.Telegram.RiskSignalTest do
  use ExUnit.Case, async: true

  alias Alethea.Alerts.CrisisMonitor
  alias Alethea.Telegram.RiskSignal
  alias Alethea.Clinical.Message

  @time ~U[2025-01-01 12:00:00Z]

  test "preserves deterministic CrisisMonitor matches as confirmed authority" do
    crisis = CrisisMonitor.detect("Me voy a matar")

    assert {:ok, signal} = RiskSignal.build(crisis, {:available, :safe}, "rules-v1", @time)
    assert signal.category == :confirmed_crisis
    assert signal.authority == :deterministic_rule
    assert length(signal.rule_matches) == 1
    assert signal.deterministic_severity == :immediate
    assert signal.detector_status == :available
  end

  test "untrusted message changesets cannot set the risk audit" do
    changeset = Message.changeset(%Message{}, %{risk_signal: %{"category" => "confirmed_crisis"}})
    refute Map.has_key?(changeset.changes, :risk_signal)
  end

  test "serializes only the bounded audit fields as JSON-safe strings" do
    crisis = CrisisMonitor.detect("Me voy a matar; texto privado")
    assert {:ok, signal} = RiskSignal.build(crisis, {:unavailable, :disabled}, "rules-v1", @time)

    serialized = RiskSignal.to_map(signal)

    assert serialized["category"] == "confirmed_crisis"
    assert serialized["authority"] == "deterministic_rule"
    assert serialized["deterministic_severity"] == "immediate"
    assert serialized["classified_at"] == "2025-01-01T12:00:00Z"
    assert serialized["detector_status"] == "unavailable"
    assert serialized["unavailable_reason"] == "disabled"
    assert Enum.all?(serialized["rule_matches"], &is_binary/1)
    refute inspect(serialized) =~ "texto privado"
  end

  test "optional escalation cannot become confirmed crisis" do
    assert {:ok, signal} = RiskSignal.build(:safe, {:available, :escalated}, "model-v1", @time)
    assert signal.category == :escalated
    assert signal.authority == :optional_signal
    assert signal.response_intent == :fixed_uncertainty
  end

  test "uncertainty has a fixed response intent" do
    assert {:ok, signal} = RiskSignal.build(:safe, {:available, :uncertain}, "model-v1", @time)
    assert signal.category == :uncertain
    assert signal.response_intent == :fixed_uncertainty
  end

  test "unavailable optional detector preserves deterministic safe result with closed reason" do
    assert {:ok, signal} = RiskSignal.build(:safe, {:unavailable, :timeout}, "model-v1", @time)
    assert signal.category == :safe
    assert signal.detector_status == :unavailable
    assert signal.unavailable_reason == :timeout
  end

  test "failure or safe optional result never downgrades deterministic crisis" do
    crisis = CrisisMonitor.detect("Quiero morir")

    for optional <- [{:available, :safe}, {:available, :uncertain}, {:unavailable, :timeout}] do
      assert {:ok, signal} = RiskSignal.build(crisis, optional, "rules-v1", @time)
      assert signal.category == :confirmed_crisis
      assert length(signal.rule_matches) == 1
      assert signal.deterministic_severity == :high
    end
  end

  test "invalid optional metadata uses safe bounded defaults without echoing it" do
    text = String.duplicate("patient text ", 100)
    assert {:ok, signal} = RiskSignal.build(:safe, {:available, :safe}, text, "not-time")
    assert signal.detector_version == "unknown"
    assert signal.classified_at != "not-time"
    refute inspect(signal) =~ text
  end

  test "deterministic crisis survives invalid optional metadata and detector outcome" do
    crisis = CrisisMonitor.detect("Me voy a matar")

    for {version, time, optional} <- [
          {"bad version\nsecret", @time, {:available, :safe}},
          {"v1", "not-time", {:available, :safe}},
          {"v1", @time, {:unavailable, "raw detector error"}}
        ] do
      assert {:ok, signal} = RiskSignal.build(crisis, optional, version, time)
      assert signal.category == :confirmed_crisis
      assert length(signal.rule_matches) == 1

      assert signal.detector_status ==
               if(
                 is_binary(version) and version == "v1" and time == @time and
                   optional == {:unavailable, "raw detector error"},
                 do: :unavailable,
                 else: :available
               )
    end
  end

  test "arbitrary rule sources are retained as bounded content-free identifiers" do
    rules = ["a/b", "x=y!", "many matches"] ++ Enum.map(1..12, &"rule/#{&1}!")
    crisis = {:crisis, :high, rules}

    assert {:ok, first} = RiskSignal.build(crisis, {:unavailable, :error}, "v1", @time)
    assert {:ok, second} = RiskSignal.build(crisis, {:unavailable, :error}, "v1", @time)
    assert first == second
    assert first.category == :confirmed_crisis
    assert first.deterministic_severity == :high
    assert first.rule_match_count == length(rules)
    assert byte_size(first.rule_digest) == 24
    assert length(first.rule_matches) <= 8
    assert Enum.all?(first.rule_matches, &(byte_size(&1) <= 64))
    refute inspect(first) =~ "a/b"
    refute inspect(first) =~ "x=y!"
    assert first.unavailable_reason == :error
  end

  test "malformed optional result has explicit unavailable semantics" do
    assert {:ok, signal} = RiskSignal.build(:safe, {:unavailable, "raw exception"}, "v1", @time)
    assert signal.category == :safe
    assert signal.detector_status == :unavailable
    assert signal.unavailable_reason == :error
  end

  test "accepts only the CrisisMonitor result and closed optional vocabulary" do
    assert {:error, :invalid_deterministic_result} =
             RiskSignal.build({:crisis, :unsupported, ["rule"]}, {:available, :safe}, "v1", @time)
  end
end
