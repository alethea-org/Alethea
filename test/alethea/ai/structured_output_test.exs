defmodule Alethea.AI.StructuredOutputTest do
  @moduledoc """
  #316 D1: `unwrap_schema_echo/1` (new, opt-in, generic `properties`
  unwrapper) and the `parse_json_response/1` trailing-fence-strip fix.
  Regression proof that the return contract
  (`{:ok, map()} | {:error, :invalid_json | :not_a_map}`) is unchanged
  for every existing behavior.
  """
  use ExUnit.Case, async: true

  alias Alethea.AI.StructuredOutput

  describe "unwrap_schema_echo/1" do
    test "unwraps a properties-wrapped map" do
      assert StructuredOutput.unwrap_schema_echo(%{"properties" => %{"f" => "v"}}) ==
               %{"f" => "v"}
    end

    test "passes through a map without a properties key unchanged" do
      assert StructuredOutput.unwrap_schema_echo(%{"f" => "v"}) == %{"f" => "v"}
    end

    test "unwraps a double-wrapped (nested properties) map recursively" do
      double_wrapped = %{"properties" => %{"properties" => %{"f" => "v"}}}
      assert StructuredOutput.unwrap_schema_echo(double_wrapped) == %{"f" => "v"}
    end

    test "passes through unchanged when properties maps to a non-map value" do
      assert StructuredOutput.unwrap_schema_echo(%{"properties" => "not a map"}) ==
               %{"properties" => "not a map"}
    end

    test "passes through an empty map unchanged" do
      assert StructuredOutput.unwrap_schema_echo(%{}) == %{}
    end
  end

  describe "parse_json_response/1 — fence stripping" do
    test "no fence: plain JSON is unchanged" do
      assert StructuredOutput.parse_json_response(~s({"a": 1})) == {:ok, %{"a" => 1}}
    end

    test "leading-only fence still decodes" do
      raw = "```json\n{\"a\": 1}"
      assert StructuredOutput.parse_json_response(raw) == {:ok, %{"a" => 1}}
    end

    test "trailing-only fence now decodes (previously errored)" do
      raw = "{\"a\": 1}\n```"
      assert StructuredOutput.parse_json_response(raw) == {:ok, %{"a" => 1}}
    end

    test "both leading and trailing fences decode" do
      raw = "```json\n{\"a\": 1}\n```"
      assert StructuredOutput.parse_json_response(raw) == {:ok, %{"a" => 1}}
    end

    test "bare fence (no json tag), both sides" do
      raw = "```\n{\"a\": 1}\n```"
      assert StructuredOutput.parse_json_response(raw) == {:ok, %{"a" => 1}}
    end

    test "whitespace-padded fence decodes" do
      raw = "   ```json   \n  {\"a\": 1}  \n   ```   "
      assert StructuredOutput.parse_json_response(raw) == {:ok, %{"a" => 1}}
    end

    test "unfenced malformed JSON is unchanged: {:error, :invalid_json}" do
      assert StructuredOutput.parse_json_response("not json at all {") ==
               {:error, :invalid_json}
    end

    test "unfenced valid non-object JSON is unchanged: {:error, :not_a_map}" do
      assert StructuredOutput.parse_json_response(~s([1, 2, 3])) == {:error, :not_a_map}
    end
  end
end
