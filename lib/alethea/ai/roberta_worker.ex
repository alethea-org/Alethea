defmodule Alethea.AI.RoBERTaWorker do
  @moduledoc """
  Worker híbrido para el análisis de emociones.
  Soporta dos proveedores:
  - :local -> Utiliza Bumblebee para inferencia en la propia máquina.
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
          compile: [batch_size: 10, sequence_length: 128]
        )

      {:ok, _} = Nx.Serving.start_link(name: @serving_name, serving: serving)
    end

    {:noreply, state}
  end

  @impl true
  def analyze_batch([]), do: empty_result()

  def analyze_batch(texts) when is_list(texts) do
    texts
    |> analyze_batch_per_message()
    |> average_score_sets()
  end

  @impl true
  def analyze_batch_per_message([]), do: []

  def analyze_batch_per_message(texts) when is_list(texts) do
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
    |> normalize_per_message_results()
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

  defp normalize_per_message_results(results) when is_list(results) do
    Enum.map(results, fn
      # Formato Bumblebee (top_k: 1)
      %{predictions: [%{label: label, score: score}]} ->
        label
        |> canonical_score_map(score)
        |> to_score_list()

      # Formato Hugging Face API (lista de listas de dicts)
      # El API suele devolver [[{"label": "...", "score": ...}, ...], ...]
      # Si enviamos batch, devuelve una lista de listas.
      [%{"label" => label, "score" => score} | _] ->
        label
        |> canonical_score_map(score)
        |> to_score_list()

      # Soporte para formato de mock simple en tests
      %{"label" => label, "score" => score} ->
        label
        |> canonical_score_map(score)
        |> to_score_list()

      %{label: label, score: score} ->
        label
        |> canonical_score_map(score)
        |> to_score_list()

      _ ->
        empty_result()
    end)
  end

  defp normalize_per_message_results(_), do: []

  defp canonical_score_map(label, score) do
    canonical =
      label
      |> to_string()
      |> String.downcase()
      |> then(&Map.get(@label_map, &1))

    if canonical, do: %{canonical => score}, else: %{}
  end

  defp to_score_list(score_map) do
    Enum.map(@canonical_labels, fn label ->
      %{label: label, score: Map.get(score_map, label, 0.0) || 0.0}
    end)
  end

  defp average_score_sets([]), do: empty_result()

  defp average_score_sets(score_sets) do
    base = Map.new(@canonical_labels, fn l -> {l, 0.0} end)

    totals =
      Enum.reduce(score_sets, base, fn emotions, acc ->
        Enum.reduce(emotions, acc, fn emotion, inner_acc ->
          label = emotion_label(emotion)
          score = emotion_score(emotion)

          if label in @canonical_labels do
            Map.update(inner_acc, label, score, &(&1 + score))
          else
            inner_acc
          end
        end)
      end)

    count = length(score_sets)

    Enum.map(@canonical_labels, fn label ->
      %{label: label, score: totals[label] / count}
    end)
  end

  defp emotion_label(%{label: label}), do: to_string(label)
  defp emotion_label(%{"label" => label}), do: to_string(label)
  defp emotion_label(_emotion), do: nil

  defp emotion_score(%{score: score}), do: score_value(score)
  defp emotion_score(%{"score" => score}), do: score_value(score)
  defp emotion_score(_emotion), do: 0.0

  defp score_value(score) when is_number(score), do: score
  defp score_value(_score), do: 0.0

  defp empty_result do
    Enum.map(@canonical_labels, fn label -> %{label: label, score: 0.0} end)
  end
end
