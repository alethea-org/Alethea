defmodule Alethea.AI.Embeddings.Ollama do
  @moduledoc """
  Ollama-backed embeddings adapter for RAG ingest (ADR-002).

  Calls the local Ollama `/api/embed` endpoint to vectorize clinical
  text using `BAAI/bge-m3` (1024-dim, multilingual). No clinical text
  leaves the host.

  ## Configuration

      config :alethea, Alethea.AI.Embeddings.Ollama,
        model: "bge-m3",
        endpoint_url: "http://localhost:11434",
        receive_timeout: 120_000

  All keys are optional; the defaults match a standard local Ollama
  install with `bge-m3` pulled.

  ## Endpoint shape (`/api/embed`)

  Ollama's `/api/embed` accepts `{"model": "bge-m3", "input": <string | [string]>}`
  and returns `{"embeddings": [[float, …], …]}` — always a list of
  lists, even for a single input.
  """

  use Alethea.AI.Embeddings

  @default_model "bge-m3"
  @default_endpoint "http://localhost:11434"
  @default_timeout 120_000
  @dimensions 1024

  @impl true
  def embed(text, opts) when is_binary(text) do
    case do_embed(text, opts) do
      {:ok, [vector]} -> {:ok, vector}
      {:ok, _other} -> {:error, :unexpected_response_shape}
      error -> error
    end
  end

  def embed(texts, opts) when is_list(texts) do
    do_embed(texts, opts)
  end

  @impl true
  def model, do: config(:model, @default_model)

  @impl true
  def dimensions, do: @dimensions

  # -- internals ----------------------------------------------------------

  defp do_embed(input, _opts) do
    url = endpoint_url() <> "/api/embed"

    payload = %{
      model: model(),
      input: input
    }

    req_opts =
      [json: payload, receive_timeout: receive_timeout()] ++
        Application.get_env(:alethea, :ollama_embeddings_req_options, [])

    case Req.post(url, req_opts) do
      {:ok, %Req.Response{status: 200, body: %{"embeddings" => embeddings}}}
      when is_list(embeddings) ->
        {:ok, embeddings}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Ollama embeddings API returned HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Ollama embeddings API request failed: #{inspect(reason)}"}
    end
  end

  defp endpoint_url do
    config(:endpoint_url, @default_endpoint) |> String.trim_trailing("/")
  end

  defp receive_timeout, do: config(:receive_timeout, @default_timeout)

  defp config(key, default) do
    :alethea
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
