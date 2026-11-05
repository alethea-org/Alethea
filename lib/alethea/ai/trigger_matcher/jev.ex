defmodule Alethea.AI.TriggerMatcher.Jev do
  @moduledoc """
  Production reactive-trigger matcher backed by TypeSafe System One (`POST /v1/systemone`) (#449).

  Evaluates candidate triggers in a single HTTP request using Noul questions.
  The global threshold from configuration decides if any trigger fires, and
  `Alethea.Triggers.ReactiveMatch` selects the highest probability above that threshold.

  ## PHI & Data Protection (S4)
  Only sanitized text leaves the system. `Alethea.AI.Sanitizer.sanitize/1` is applied
  to both the patient message (`state`) and each candidate trigger's condition text
  before constructing the outbound JSON payload. Embeddings are never generated or sent.
  """

  @behaviour Alethea.AI.TriggerMatcherBehaviour

  alias Alethea.AI.Sanitizer

  @default_base_url "https://api.typesafe.ai"
  @default_model "jev-latest"
  @default_timeout_ms 5_000

  @impl true
  def match(text, candidates) when is_binary(text) and is_list(candidates) do
    match(text, candidates, [])
  end

  def match(_text, _candidates), do: {:error, :invalid_input}

  @doc """
  Matches `text` against `candidates` using explicit `opts` merged with
  application configuration (`:jev_trigger_matcher`).
  """
  @spec match(String.t(), [Alethea.AI.TriggerMatcherBehaviour.candidate()], keyword()) ::
          {:ok, Alethea.AI.TriggerMatcherBehaviour.probabilities()} | {:error, term()}
  def match(text, [], _opts) when is_binary(text) do
    {:ok, %{}}
  end

  def match(text, candidates, opts)
      when is_binary(text) and is_list(candidates) and is_list(opts) do
    config = Keyword.merge(Application.get_env(:alethea, :jev_trigger_matcher, []), opts)
    api_key = config[:api_key]

    with :ok <- validate_api_key(api_key),
         {:ok, body} <- build_request_body(text, candidates, config),
         {:ok, response} <- execute_request(body, api_key, config) do
      parse_response(response, candidates)
    end
  rescue
    error -> {:error, error}
  end

  def match(_text, _candidates, _opts), do: {:error, :invalid_input}

  defp validate_api_key(key) when is_binary(key) do
    if String.trim(key) != "" do
      :ok
    else
      {:error, :missing_api_key}
    end
  end

  defp validate_api_key(_key), do: {:error, :missing_api_key}

  defp build_request_body(text, candidates, config) do
    sanitized_text = Sanitizer.sanitize(text)
    model = config[:model] || @default_model

    questions =
      Map.new(candidates, fn %{id: id, condition: condition} ->
        sanitized_cond = Sanitizer.sanitize(condition)

        {to_string(id),
         %{
           "type" => "noul",
           "instructions" =>
             "Determina si el mensaje del paciente describe, menciona o cumple la siguiente condición: #{sanitized_cond}",
           "criteria" => %{
             "true" => "El mensaje del paciente cumple la condición: #{sanitized_cond}",
             "false" => "El mensaje del paciente no cumple la condición: #{sanitized_cond}"
           }
         }}
      end)

    {:ok,
     %{
       "model" => model,
       "state" => sanitized_text,
       "questions" => questions
     }}
  end

  defp execute_request(body, api_key, config) do
    base_url = config[:base_url] || @default_base_url
    url = String.trim_trailing(base_url, "/") <> "/v1/systemone"

    timeout_ms =
      config[:timeout_ms] ||
        config[:receive_timeout] ||
        Application.get_env(:alethea, :trigger_match_timeout_ms, @default_timeout_ms)

    req_options = config[:req_options] || []

    req_opts =
      [
        json: body,
        headers: [{"authorization", "Bearer " <> api_key}],
        retry: false,
        redirect: false,
        receive_timeout: timeout_ms
      ]
      |> maybe_put(:plug, config[:plug])
      |> Keyword.merge(req_options)

    case Req.post(url, req_opts) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, %Req.TransportError{reason: reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_response(%Req.Response{status: 200, body: %{"answers" => answers}}, candidates)
       when is_map(answers) do
    Enum.reduce_while(candidates, {:ok, %{}}, fn candidate, {:ok, acc} ->
      candidate_id_str = to_string(candidate.id)

      case Map.get(answers, candidate_id_str) do
        %{"noul" => p} when is_number(p) and p >= 0.0 and p <= 1.0 ->
          {:cont, {:ok, Map.put(acc, candidate.id, p * 1.0)}}

        _missing_or_invalid ->
          {:halt, {:error, {:invalid_answer, candidate_id_str}}}
      end
    end)
  end

  defp parse_response(%Req.Response{status: 200}, _candidates), do: {:error, :malformed_response}

  defp parse_response(%Req.Response{status: status}, _candidates) when is_integer(status) do
    {:error, {:http_error, status}}
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
