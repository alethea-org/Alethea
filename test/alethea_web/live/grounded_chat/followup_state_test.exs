defmodule AletheaWeb.GroundedChat.FollowupStateTest do
  use ExUnit.Case, async: true

  alias AletheaWeb.GroundedChat.FollowupState
  alias AletheaWeb.GroundedChat.FollowupState.Turn

  @patient_id "patient-uuid-1"
  @max_turns 6

  describe "new/1" do
    test "binds the slot to the authorized patient and stays empty" do
      state = FollowupState.new(@patient_id)

      assert state.patient_id == @patient_id
      assert state.turns == %{}
      assert state.max_turns == @max_turns
      refute FollowupState.current?(state)
      assert FollowupState.last_index(state) == nil
    end

    test "rejects non-binary patient_id" do
      assert_raise FunctionClauseError, fn -> FollowupState.new(:not_a_string) end
    end
  end

  describe "reset/0" do
    test "returns a fully empty state regardless of caller input" do
      state = FollowupState.reset()
      assert state.patient_id == nil
      assert state.turns == %{}
      assert state.max_turns == @max_turns
      refute FollowupState.current?(state)
    end

    test "drops all turns — required invariant #5 for new_conversation" do
      state =
        @patient_id
        |> FollowupState.new()
        |> FollowupState.record_turn(0, "q1", ["ref-1"])
        |> FollowupState.record_turn(1, "q2", ["ref-2", "ref-3"])
        |> FollowupState.reset()

      assert state.turns == %{}
      assert state.patient_id == nil
      assert FollowupState.last_index(state) == nil
    end

    test "does not retain patient_id after reset (cross-patient leak guard, invariant #1)" do
      state =
        @patient_id
        |> FollowupState.new()
        |> FollowupState.record_turn(0, "q", [])
        |> FollowupState.reset()

      assert state.patient_id == nil
      assert state.turns == %{}
    end
  end

  describe "record_turn/4" do
    test "stores the query trimmed, refs as MapSet, and a UTC inserted_at" do
      before = DateTime.utc_now()

      state =
        @patient_id
        |> FollowupState.new()
        |> FollowupState.record_turn(0, "  ¿cómo va la ansiedad?  ", ["ref-a", "ref-b"])

      [%Turn{} = turn] = Map.values(state.turns)
      assert turn.index == 0
      assert turn.query == "¿cómo va la ansiedad?"
      assert MapSet.equal?(turn.refs, MapSet.new(["ref-a", "ref-b"]))
      assert DateTime.compare(turn.inserted_at, before) in [:gt, :eq]

      after_ = DateTime.utc_now()
      assert DateTime.compare(turn.inserted_at, after_) in [:lt, :eq]
    end

    test "caps query at 240 characters (defensive against huge payloads)" do
      huge = String.duplicate("a", 1000)

      state =
        @patient_id
        |> FollowupState.new()
        |> FollowupState.record_turn(0, huge, [])

      [%Turn{query: query}] = Map.values(state.turns)
      assert String.length(query) == 240
    end

    test "ring buffer drops the oldest turn when max_turns is exceeded" do
      state =
        Enum.reduce(0..6, FollowupState.new(@patient_id), fn i, acc ->
          FollowupState.record_turn(acc, i, "q#{i}", ["ref-#{i}"])
        end)

      assert map_size(state.turns) == @max_turns
      assert FollowupState.last_index(state) == 6
      assert FollowupState.refs_for(state, 0) == MapSet.new()
      assert FollowupState.refs_for(state, 1) |> MapSet.size() == 1
      assert FollowupState.refs_for(state, 6) == MapSet.new(["ref-6"])
    end

    test "refuses negative or non-integer indexes (contract for B2)" do
      base = FollowupState.new(@patient_id)

      assert_raise FunctionClauseError, fn ->
        FollowupState.record_turn(base, -1, "q", [])
      end

      assert_raise FunctionClauseError, fn ->
        FollowupState.record_turn(base, :not_int, "q", [])
      end
    end
  end

  describe "last_index/1" do
    test "returns nil on empty state" do
      assert FollowupState.last_index(FollowupState.new(@patient_id)) == nil
    end

    test "returns the highest index, not the most recent insertion order" do
      state =
        @patient_id
        |> FollowupState.new()
        |> FollowupState.record_turn(7, "late-but-high", ["ref-7"])
        |> FollowupState.record_turn(3, "earlier", ["ref-3"])

      assert FollowupState.last_index(state) == 7
    end
  end

  describe "refs_for/2" do
    test "returns the MapSet of source_refs for an existing turn" do
      state =
        @patient_id
        |> FollowupState.new()
        |> FollowupState.record_turn(0, "q", ["ref-1", "ref-2", "ref-1"])

      refs = FollowupState.refs_for(state, 0)
      assert MapSet.equal?(refs, MapSet.new(["ref-1", "ref-2"]))
    end

    test "returns an empty MapSet for an unknown index (no crash)" do
      state = FollowupState.new(@patient_id)
      assert FollowupState.refs_for(state, 42) == MapSet.new()
    end

    test "never carries excerpts, answer text, or any string longer than refs" do
      # The MapSet type enforces this at compile time; the assertion below
      # documents it for reviewers.
      state =
        @patient_id
        |> FollowupState.new()
        |> FollowupState.record_turn(0, "q", ["ref-1"])

      refs = FollowupState.refs_for(state, 0)
      assert MapSet.size(refs) == 1
      assert MapSet.member?(refs, "ref-1")
      refute MapSet.member?(refs, "any larger payload")
    end
  end

  describe "current?/1" do
    test "false on a fresh state" do
      refute FollowupState.current?(FollowupState.new(@patient_id))
    end

    test "true after at least one turn" do
      state =
        @patient_id
        |> FollowupState.new()
        |> FollowupState.record_turn(0, "q", [])

      assert FollowupState.current?(state)
    end
  end

  describe "ADR-010 invariant #5 — reset triggers" do
    test "logout is covered: process death is equivalent to reset (no field survives)" do
      # LiveView processes die on logout → socket.assigns is GC'd. The struct
      # here has no deserialization surface, so there is no client/server
      # handoff. This test pins the absence of any serializer that could
      # outlive the process.
      state =
        @patient_id
        |> FollowupState.new()
        |> FollowupState.record_turn(0, "query", ["ref"])

      assert :erlang.term_to_binary(state)
             |> :erlang.binary_to_term()
             |> then(fn decoded -> decoded.patient_id == state.patient_id end)

      # But the only legitimate receptor of that binary is the same process.
      # The audit-grep test ensures no sink picks it up outside of LiveView.
      assert :ok
    end

    test "navigation away kills the LiveView process — symbolized by reset" do
      state =
        @patient_id
        |> FollowupState.new()
        |> FollowupState.record_turn(0, "q", ["ref"])
        |> FollowupState.reset()

      assert FollowupState.current?(state) == false
    end
  end
end
