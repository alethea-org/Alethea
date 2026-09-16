defmodule Alethea.AI.Embeddings.OllamaTest do
  @moduledoc """
  Tests for `Alethea.AI.Embeddings.Ollama`.

  Uses `Req.Test` to stub the outbound HTTP call so these tests
  run without a live Ollama instance (CI-safe, async).
  """

  use ExUnit.Case, async: true

  alias Alethea.AI.Embeddings.Ollama

  # -- helpers -----------------------------------------------------------

  defp stub_ollama(plug_fun) do
    # Route Req through the test plug for this test process.
    Req.Test.stub(:ollama_embeddings, plug_fun)
  end

  defp with_ollama_config(overrides \\ [], fun) do
    base = [
      model: "bge-m3",
      endpoint_url: "http://localhost:11434",
      receive_timeout: 5_000
    ]

    merged = Keyword.merge(base, overrides)

    prev = Application.get_env(:alethea, Ollama)
    prev_req = Application.get_env(:alethea, :ollama_embeddings_req_options)

    Application.put_env(:alethea, Ollama, merged)

    Application.put_env(:alethea, :ollama_embeddings_req_options,
      plug: {Req.Test, :ollama_embeddings}
    )

    try do
      fun.()
    after
      if prev,
        do: Application.put_env(:alethea, Ollama, prev),
        else: Application.delete_env(:alethea, Ollama)

      if prev_req,
        do: Application.put_env(:alethea, :ollama_embeddings_req_options, prev_req),
        else: Application.delete_env(:alethea, :ollama_embeddings_req_options)
    end
  end

  defp fake_vector(dims \\ 1024) do
    Enum.map(1..dims, fn i -> i * 0.001 end)
  end

  # -- tests -------------------------------------------------------------

  describe "model/0" do
    test "returns the configured model name" do
      with_ollama_config([model: "bge-m3"], fn ->
        assert Ollama.model() == "bge-m3"
      end)
    end
  end

  describe "dimensions/0" do
    test "returns 1024" do
      assert Ollama.dimensions() == 1024
    end
  end

  describe "embed/2 with a single string" do
    test "returns a flat vector for a single text input" do
      vector = fake_vector()

      stub_ollama(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["model"] == "bge-m3"
        assert decoded["input"] == "hola clínica"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"embeddings" => [vector]}))
      end)

      with_ollama_config(fn ->
        assert {:ok, result} = Ollama.embed("hola clínica", [])
        assert length(result) == 1024
        assert result == vector
      end)
    end
  end

  describe "embed/2 with a list of strings" do
    test "returns one vector per input, in order" do
      vec1 = fake_vector()
      vec2 = Enum.map(fake_vector(), &(&1 * 2))

      stub_ollama(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["input"] == ["uno", "dos"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"embeddings" => [vec1, vec2]}))
      end)

      with_ollama_config(fn ->
        assert {:ok, [r1, r2]} = Ollama.embed(["uno", "dos"], [])
        assert r1 == vec1
        assert r2 == vec2
      end)
    end
  end

  describe "error handling" do
    test "returns error on non-200 status" do
      stub_ollama(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "model not found"}))
      end)

      with_ollama_config(fn ->
        assert {:error, msg} = Ollama.embed("test", [])
        assert msg =~ "HTTP 500"
      end)
    end

    test "returns error on connection failure" do
      stub_ollama(fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      with_ollama_config(fn ->
        assert {:error, msg} = Ollama.embed("test", [])
        assert msg =~ "request failed"
      end)
    end
  end
end
