defmodule Alethea.AI.TriggerMatcher.JevTest do
  @moduledoc """
  Unit and integration tests for `Alethea.AI.TriggerMatcher.Jev` (#449, S1-S4).
  """

  use ExUnit.Case, async: true

  alias Alethea.AI.TriggerMatcher.Jev
  alias Alethea.TriggerMatcherEvalSet
  alias Alethea.Triggers.ReactiveMatch
  alias Alethea.Triggers.Trigger

  @api_key "test-typesafe-key-12345"
  @default_opts [
    api_key: @api_key,
    base_url: "https://api.typesafe.ai",
    model: "jev-latest"
  ]

  # ----------------------------------------------------------------
  # S1: API Contract & Request/Response Shape
  # ----------------------------------------------------------------

  describe "S1: POST /v1/systemone request and response parsing" do
    test "constructs POST /v1/systemone request with auth, model, state, and noul questions" do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:http_request, conn, decoded})

        answers = %{
          "c-1" => %{"type" => "noul", "noul" => 0.85},
          "c-2" => %{"type" => "noul", "noul" => 0.12}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"model" => "jev-latest", "answers" => answers})
        )
      end

      candidates = [
        %{id: "c-1", condition: "Habla de su madre"},
        %{id: "c-2", condition: "Menciona insomnio"}
      ]

      assert {:ok, probabilities} =
               Jev.match("Ayer discutí con mi mamá", candidates, [plug: plug] ++ @default_opts)

      assert probabilities == %{"c-1" => 0.85, "c-2" => 0.12}

      assert_received {:http_request, conn, payload}
      assert conn.method == "POST"
      assert conn.request_path == "/v1/systemone"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @api_key]

      assert payload["model"] == "jev-latest"
      assert payload["state"] == "Ayer discutí con mi mamá"
      assert is_map(payload["questions"])
      assert Map.keys(payload["questions"]) |> Enum.sort() == ["c-1", "c-2"]

      q1 = payload["questions"]["c-1"]
      assert q1["type"] == "noul"
      assert is_binary(q1["instructions"]) and q1["instructions"] =~ "Habla de su madre"
      assert is_map(q1["criteria"])
      assert is_binary(q1["criteria"]["true"])
      assert is_binary(q1["criteria"]["false"])
    end

    test "respects custom model and base_url options" do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:custom_request, conn.request_path, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "model" => "jev-custom",
            "answers" => %{"c-1" => %{"type" => "noul", "noul" => 0.9}}
          })
        )
      end

      opts = [
        plug: plug,
        api_key: "custom-key",
        base_url: "https://custom.endpoint.ai/api",
        model: "jev-custom"
      ]

      assert {:ok, %{"c-1" => 0.9}} =
               Jev.match("Texto", [%{id: "c-1", condition: "Condición"}], opts)

      assert_received {:custom_request, path, payload}
      assert path == "/api/v1/systemone"
      assert payload["model"] == "jev-custom"
    end
  end

  # ----------------------------------------------------------------
  # S2: Spanish Synthetic Evaluation Set
  # ----------------------------------------------------------------

  describe "S2: Spanish synthetic evaluation set" do
    test "passes all evaluation set categories through Jev and ReactiveMatch at threshold 0.7" do
      threshold = 0.7

      for eval_case <- TriggerMatcherEvalSet.cases() do
        plug = fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          _decoded = Jason.decode!(body)

          answers =
            Map.new(eval_case.candidates, fn candidate ->
              {candidate.id, %{"type" => "noul", "noul" => candidate.mock_noul}}
            end)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"answers" => answers}))
        end

        candidates =
          Enum.map(eval_case.candidates, fn c ->
            %{id: c.id, condition: c.condition}
          end)

        assert {:ok, probabilities} =
                 Jev.match(eval_case.patient_message, candidates, [plug: plug] ++ @default_opts)

        scored =
          Enum.map(eval_case.candidates, fn c ->
            {%Trigger{id: c.id, decrypted_approved_text: c.approved_text, kind: "reactive"},
             Map.fetch!(probabilities, c.id)}
          end)

        match_result = ReactiveMatch.select_match(scored, threshold)

        case eval_case.expected_match_id do
          nil ->
            assert match_result == :none,
                   "Expected no match for #{inspect(eval_case.id)} (#{eval_case.description}), got: #{inspect(match_result)}"

          expected_id ->
            assert {:ok, {%Trigger{id: ^expected_id}, prob}} = match_result,
                   "Expected match #{expected_id} for #{inspect(eval_case.id)}, got: #{inspect(match_result)}"

            assert prob >= threshold
        end
      end
    end
  end

  # ----------------------------------------------------------------
  # S3: Error Handling and Degrade to :none
  # ----------------------------------------------------------------

  describe "S3: Error handling and degradation" do
    test "empty candidate list returns {:ok, %{}} with zero HTTP calls" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, :unexpected_http_call)
        Plug.Conn.send_resp(conn, 200, "{}")
      end

      assert {:ok, %{}} = Jev.match("Cualquier texto", [], [plug: plug] ++ @default_opts)
      refute_received :unexpected_http_call
    end

    test "missing or blank API key returns {:error, :missing_api_key}" do
      assert {:error, :missing_api_key} =
               Jev.match("Texto", [%{id: "1", condition: "Condición"}], api_key: nil)

      assert {:error, :missing_api_key} =
               Jev.match("Texto", [%{id: "1", condition: "Condición"}], api_key: "")

      assert {:error, :missing_api_key} =
               Jev.match("Texto", [%{id: "1", condition: "Condición"}], api_key: "   ")
    end

    test "non-200 HTTP statuses return {:error, {:http_error, status}}" do
      for status <- [400, 401, 422, 429, 500, 529] do
        plug = fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, Jason.encode!(%{"error" => "status #{status}"}))
        end

        assert {:error, {:http_error, ^status}} =
                 Jev.match(
                   "Texto",
                   [%{id: "1", condition: "Condición"}],
                   [plug: plug] ++ @default_opts
                 )
      end
    end

    test "malformed responses return error" do
      # Not a JSON map
      plug_not_map = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(["not", "a", "map"]))
      end

      assert {:error, :malformed_response} =
               Jev.match(
                 "Texto",
                 [%{id: "1", condition: "C"}],
                 [plug: plug_not_map] ++ @default_opts
               )

      # Missing answers key
      plug_no_answers = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"status" => "ok"}))
      end

      assert {:error, :malformed_response} =
               Jev.match(
                 "Texto",
                 [%{id: "1", condition: "C"}],
                 [plug: plug_no_answers] ++ @default_opts
               )

      # Candidate answer missing
      plug_missing_candidate = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"answers" => %{"other-id" => %{"noul" => 0.8}}})
        )
      end

      assert {:error, {:invalid_answer, "1"}} =
               Jev.match(
                 "Texto",
                 [%{id: "1", condition: "C"}],
                 [plug: plug_missing_candidate] ++ @default_opts
               )
    end

    test "out-of-range or non-numeric noul values return error" do
      for invalid_noul <- [-0.1, 1.01, 2.0, "high", nil] do
        plug = fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "answers" => %{"1" => %{"type" => "noul", "noul" => invalid_noul}}
            })
          )
        end

        assert {:error, {:invalid_answer, "1"}} =
                 Jev.match("Texto", [%{id: "1", condition: "C"}], [plug: plug] ++ @default_opts)
      end
    end

    test "transport and timeout errors return error" do
      plug_transport = fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end

      assert {:error, :econnrefused} =
               Jev.match(
                 "Texto",
                 [%{id: "1", condition: "C"}],
                 [plug: plug_transport] ++ @default_opts
               )

      plug_timeout = fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end

      assert {:error, :timeout} =
               Jev.match(
                 "Texto",
                 [%{id: "1", condition: "C"}],
                 [plug: plug_timeout] ++ @default_opts
               )
    end
  end

  # ----------------------------------------------------------------
  # S4: Privacy & Sanitization
  # ----------------------------------------------------------------

  describe "S4: Sanitization and no embeddings" do
    test "sanitizes text and candidate conditions before creating outbound request" do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:outbound_payload, decoded})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "answers" => %{"c-1" => %{"type" => "noul", "noul" => 0.5}}
          })
        )
      end

      raw_burst = "Mi teléfono es +56 9 1234 5678 y mi rut es 123456789. Escribir a juan@test.com"
      raw_condition = "Contactar al médico al +56 9 8765 4321 o email doctor@clinica.cl"

      assert {:ok, _} =
               Jev.match(
                 raw_burst,
                 [%{id: "c-1", condition: raw_condition}],
                 [plug: plug] ++ @default_opts
               )

      assert_received {:outbound_payload, payload}

      # State text sanitization
      state = payload["state"]
      refute state =~ "juan@test.com"
      refute state =~ "12345678"
      refute state =~ "123456789"
      assert state =~ "[REDACTED_EMAIL]"
      assert state =~ "[REDACTED_PHONE]"
      assert state =~ "[REDACTED_ID]"

      # Condition sanitization
      question = payload["questions"]["c-1"]
      instructions = question["instructions"]
      refute instructions =~ "doctor@clinica.cl"
      refute instructions =~ "8765"
      assert instructions =~ "[REDACTED_EMAIL]"
      assert instructions =~ "[REDACTED_PHONE]"

      # Never send embeddings field
      refute Map.has_key?(payload, "embedding")
      refute Map.has_key?(payload, "embeddings")

      for {_k, q} <- payload["questions"] do
        refute Map.has_key?(q, "embedding")
        refute Map.has_key?(q, "embeddings")
      end
    end
  end

  describe "Application environment timeout configuration" do
    test "falls back to Application.get_env(:alethea, :trigger_match_timeout_ms) when timeout is not passed in opts" do
      original_timeout = Application.get_env(:alethea, :trigger_match_timeout_ms)

      try do
        Application.put_env(:alethea, :trigger_match_timeout_ms, 12_345)
        test_pid = self()

        finch_spy = fn req, _finch_req, _finch_name, finch_opts ->
          send(test_pid, {:finch_receive_timeout, finch_opts[:receive_timeout]})

          answers = %{
            "c-1" => %{"type" => "noul", "noul" => 0.5}
          }

          {req, Req.Response.new(status: 200, body: %{"answers" => answers})}
        end

        opts = [req_options: [finch_request: finch_spy]] ++ @default_opts

        assert {:ok, _} = Jev.match("Texto", [%{id: "c-1", condition: "Condición"}], opts)
        assert_received {:finch_receive_timeout, 12_345}
      after
        if original_timeout do
          Application.put_env(:alethea, :trigger_match_timeout_ms, original_timeout)
        else
          Application.delete_env(:alethea, :trigger_match_timeout_ms)
        end
      end
    end
  end
end
