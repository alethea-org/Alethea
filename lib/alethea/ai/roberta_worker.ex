defmodule Alethea.AI.RoBERTaWorker do
  @moduledoc """
  Worker híbrido para el análisis de emociones.
  Soporta dos proveedores:
  - :local -> Utiliza Bumblebee y EXLA para inferencia en la propia máquina.
  - :huggingface -> Utiliza la API de Inferencia de Hugging Face (ideal para dev).
  """
  use GenServer
  @behaviour Alethea.AI.RoBERTaWorkerBehavior

  @canonical_labels ~w(joy sadness anger fear neutral)
  @model_name "pysentimiento/robertuito-emotion-analysis"
  @serving_name Alethea.AI.RoBERTaServing

  @label_map %{
    "joy" => "joy",
    "alegría" => "joy",
    "alegria" => "joy",
    "sadness" => "sadness",
    "tristeza" => "sadness",
    "anger" => "anger",
    "ira" => "anger",
    "fear" => "fear",
    "miedo" => "fear",
    "neutral" => "neutral",
    "others" => "neutral",
    "surprise" => nil,
    "disgust" => nil
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :load_model}}
  end

  @impl true
  def handle_continue(:load_model, state) do
    config = Application.get_env(:alethea, __MODULE__, [])
    provider = Keyword.get(config, :provider, :local)

    # Solo cargamos el modelo local si el proveedor es :local
    if provider == :local and Application.get_env(:alethea, :start_ai, true) do
      {:ok, model_info} = Bumblebee.load_model({:hf, @model_name})
      {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, @model_name})

      serving =
        Bumblebee.Text.text_classification(model_info, tokenizer,
          top_k: 1,
          compile: [batch_size: 10, sequence_length: 128],
          defn_options: [compiler: EXLA]
        )

      {:ok, _} = Nx.Serving.start_link(name: @serving_name, serving: serving)
    end

    {:noreply, state}
  end

  @impl true
  def analyze_batch([]), do: empty_result()

  def analyze_batch(texts) when is_list(texts) do
    config = Application.get_env(:alethea, __MODULE__, [])
    provider = Keyword.get(config, :provider, :local)

    results =
      case provider do
        :huggingface ->
          run_huggingface(texts, config[:huggingface])

        _local ->
          default_runner = fn text -> Nx.Serving.batched_run(@serving_name, text) end
          runner = Application.get_env(:alethea, :roberta_runner, default_runner)
          runner.(texts)
      end

    results
    |> normalize_results()
    |> average_scores(length(texts))
  end

  defp run_huggingface(texts, hf_config) do
    api_url = hf_config[:api_url]
    api_key = hf_config[:api_key]

    response =
      Req.post!(api_url,
        json: %{inputs: texts},
        headers: [{"Authorization", "Bearer #{api_key}"}],
        receive_timeout: 30_000
      )

    response.body
  end

  defp normalize_results(results) when is_list(results) do
    Enum.map(results, fn
      # Formato Bumblebee (top_k: 1)
      %{predictions: [%{label: label, score: score}]} ->
        canonical = Map.get(@label_map, String.downcase(label))
        if canonical, do: %{canonical => score}, else: %{}

      # Formato Hugging Face API (lista de listas de dicts)
      # El API suele devolver [[{"label": "...", "score": ...}, ...], ...]
      # Si enviamos batch, devuelve una lista de listas.
      [%{"label" => label, "score" => score} | _] ->
        canonical = Map.get(@label_map, String.downcase(label))
        if canonical, do: %{canonical => score}, else: %{}

      # Soporte para formato de mock simple en tests
      %{"label" => label, "score" => score} ->
        canonical = Map.get(@label_map, String.downcase(label))
        if canonical, do: %{canonical => score}, else: %{}

      _ ->
        %{}
    end)
  end

  defp normalize_results(_), do: []

  defp average_scores(normalized_list, count) do
    base = Map.new(@canonical_labels, fn l -> {l, 0.0} end)

    totals =
      Enum.reduce(normalized_list, base, fn emotions, acc ->
        Enum.reduce(emotions, acc, fn {label, score}, inner_acc ->
          Map.update(inner_acc, label, score, &(&1 + score))
        end)
      end)

    Enum.map(@canonical_labels, fn label ->
      %{label: label, score: totals[label] / count}
    end)
  end

  defp empty_result do
    Enum.map(@canonical_labels, fn label -> %{label: label, score: 0.0} end)
  end
end
