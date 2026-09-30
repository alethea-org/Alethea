defmodule Alethea.AI.Chains.WeeklySummaryChainTest do
  @moduledoc """
  Specs for `Alethea.AI.Chains.WeeklySummaryChain.parse/2` (#360): a model
  response that echoes the JSON schema embedded in the system prompt must be
  rejected (`{:error, :schema_echo}`) instead of being saved as a clinical
  narrative with a keyword-scanned — possibly maximum-severity — status.
  Pure parser tests only; no live LLM endpoint is invoked (mirrors
  `functional_analysis_draft_chain_test.exs`).
  """
  use ExUnit.Case, async: true

  alias Alethea.AI.Chains.WeeklySummaryChain
  alias Alethea.AI.StructuredOutput

  # The exact schema echo reported in GitHub #360: the model repeated the
  # embedded schema instead of answering with clinical data.
  @issue_echo ~s({"properties":{"summary_text":{"type":"string"},"status_level":{"enum":["Estable","Alerta","Intervención Requerida"]}},"required":["summary_text","status_level"],"type":"object"})

  @real_summary_text "Semana con mejora sostenida del ánimo, mejor descanso y sin crisis."

  @valid_response %{
    "summary_text" => @real_summary_text,
    "status_level" => "Alerta",
    "anxiety_score" => 0.42,
    "social_score" => 0.6,
    "emotional_range" => %{
      "joy" => 0.5,
      "sadness" => 0.1,
      "anger" => 0.0,
      "fear" => 0.2,
      "neutral" => 0.3
    },
    "crisis_events" => 1,
    "session_count" => 5
  }

  describe "parse/2 — schema echo rejection (#360)" do
    test "rejects the exact schema echo from the issue" do
      assert {:error, :schema_echo} = WeeklySummaryChain.parse(@issue_echo, 1)
    end

    test "rejects an echo of the actual embedded weekly summary schema" do
      echo = Jason.encode!(StructuredOutput.weekly_summary_schema())

      assert {:error, :schema_echo} = WeeklySummaryChain.parse(echo, 2)
    end

    test "rejects a properties wrapper whose values are field definitions" do
      wrapper =
        Jason.encode!(%{
          "properties" => %{
            "summary_text" => %{"type" => "string"},
            "status_level" => %{"enum" => ["Estable", "Alerta", "Intervención Requerida"]}
          }
        })

      assert {:error, :schema_echo} = WeeklySummaryChain.parse(wrapper, 1)
    end

    test "rejects a double properties wrapper" do
      double =
        Jason.encode!(%{
          "properties" => %{
            "properties" => %{
              "summary_text" => %{"type" => "string"},
              "status_level" => %{"type" => "string"}
            }
          }
        })

      assert {:error, :schema_echo} = WeeklySummaryChain.parse(double, 1)
    end

    test "rejects the full schema shape (type object + required list) without properties" do
      shape =
        Jason.encode!(%{
          "type" => "object",
          "required" => ["summary_text", "status_level"],
          "summary_text" => %{"type" => "string"},
          "status_level" => %{"enum" => ["Estable", "Alerta", "Intervención Requerida"]}
        })

      assert {:error, :schema_echo} = WeeklySummaryChain.parse(shape, 1)
    end

    test "no echo path ever derives a report from the schema text" do
      for echo <- [@issue_echo, Jason.encode!(StructuredOutput.weekly_summary_schema())] do
        refute match?({:ok, _report}, WeeklySummaryChain.parse(echo, 1))
      end
    end
  end

  describe "parse/2 — unparseable responses" do
    test "rejects a non-JSON narrative" do
      narrative = "El paciente tuvo una semana estable y tranquila."

      assert {:error, :unparseable} = WeeklySummaryChain.parse(narrative, 1)
    end

    test "rejects a blank summary_text" do
      json = Jason.encode!(%{"summary_text" => "   ", "status_level" => "Estable"})

      assert {:error, :unparseable} = WeeklySummaryChain.parse(json, 1)
    end

    test "rejects a missing summary_text" do
      json = Jason.encode!(%{"status_level" => "Estable", "session_count" => 2})

      assert {:error, :unparseable} = WeeklySummaryChain.parse(json, 1)
    end

    test "rejects a non-binary summary_text" do
      json =
        Jason.encode!(%{"summary_text" => %{"type" => "string"}, "status_level" => "Estable"})

      assert {:error, :unparseable} = WeeklySummaryChain.parse(json, 1)
    end

    test "rejects a missing status_level" do
      json = Jason.encode!(%{"summary_text" => @real_summary_text})

      assert {:error, :unparseable} = WeeklySummaryChain.parse(json, 1)
    end

    test "rejects a status_level outside the clinical enum" do
      for status <- ["Crítico", "estable", "", nil] do
        json = Jason.encode!(%{"summary_text" => @real_summary_text, "status_level" => status})

        assert {:error, :unparseable} = WeeklySummaryChain.parse(json, 1)
      end
    end
  end

  describe "parse/2 — valid responses" do
    test "parses a complete response with every metric" do
      assert {:ok, report} = WeeklySummaryChain.parse(Jason.encode!(@valid_response), 3)

      assert report == %{
               summary_text: @real_summary_text,
               status_level: "Alerta",
               anxiety_score: 0.42,
               social_score: 0.6,
               emotional_range: %{
                 "joy" => 0.5,
                 "sadness" => 0.1,
                 "anger" => 0.0,
                 "fear" => 0.2,
                 "neutral" => 0.3
               },
               crisis_events: 1,
               session_count: 5
             }
    end

    test "falls back to the local session count when the model omits it" do
      json =
        Jason.encode!(%{
          "summary_text" => @real_summary_text,
          "status_level" => "Estable"
        })

      assert {:ok, report} = WeeklySummaryChain.parse(json, 4)

      assert report.session_count == 4
    end

    test "falls back to the local session count when the model garbles it" do
      json =
        Jason.encode!(%{
          "summary_text" => @real_summary_text,
          "status_level" => "Estable",
          "session_count" => "tres"
        })

      assert {:ok, report} = WeeklySummaryChain.parse(json, 4)

      assert report.session_count == 4
    end

    test "accepts a fenced json code block" do
      fenced = "```json\n" <> Jason.encode!(@valid_response) <> "\n```"

      assert {:ok, report} = WeeklySummaryChain.parse(fenced, 3)

      assert report.summary_text == @real_summary_text
      assert report.status_level == "Alerta"
      assert report.crisis_events == 1
    end

    test "accepts properties-wrapped real clinical data (#316 D1 semantics)" do
      wrapped =
        Jason.encode!(%{
          "properties" => %{
            "summary_text" => @real_summary_text,
            "status_level" => "Estable",
            "anxiety_score" => 0.3
          }
        })

      assert {:ok, report} = WeeklySummaryChain.parse(wrapped, 2)

      assert report.summary_text == @real_summary_text
      assert report.status_level == "Estable"
      assert report.anxiety_score == 0.3
      # The local session count survives the unwrap.
      assert report.session_count == 2
    end
  end
end
