defmodule Alethea.AI.RoBERTaWorker do
  @moduledoc """
  Worker local que utiliza Bumblebee para el análisis de emociones.
  Carga el modelo pysentimiento/robertuito-emotion-analysis y expone un Nx.Serving.
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
    if Application.get_env(:alethea, :start_ai, true) do
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
    # Permitir inyectar un runner para tests
    runner = Application.get_env(:alethea, :roberta_runner, &Nx.Serving.run(@serving_name, &1))
    results = runner.(texts)

    results
    |> normalize_results()
    |> average_scores(length(texts))
  end

  defp normalize_results(results) do
    Enum.map(results, fn
      %{predictions: [%{label: label, score: score}]} ->
        canonical = Map.get(@label_map, String.downcase(label))
        if canonical, do: %{canonical => score}, else: %{}

      # Soporte para formato de mock simple en tests
      %{"label" => label, "score" => score} ->
        canonical = Map.get(@label_map, String.downcase(label))
        if canonical, do: %{canonical => score}, else: %{}

      # Soporte para lista de predicciones (si no se usa top_k: 1)
      [%{label: label, score: score} | _] ->
        canonical = Map.get(@label_map, String.downcase(label))
        if canonical, do: %{canonical => score}, else: %{}

      _ ->
        %{}
    end)
  end

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
