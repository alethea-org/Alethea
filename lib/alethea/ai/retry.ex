defmodule Alethea.AI.Retry do
  @moduledoc """
  Retry con backoff exponencial para llamadas a LLM.

  Maneja:
  - Errores transitorios (503 model loading, timeout, rate limit)
  - Circuit breaker para prevenir cascading failures
  - Métricas de retry en telemetry
  """

  alias LangChain.LangChainError

  @type retry_option ::
          {:max_attempts, pos_integer()}
          | {:base_delay_ms, non_neg_integer()}
          | {:max_delay_ms, non_neg_integer()}
          | {:retry_on, [atom()]}
  @type t :: %__MODULE__{
          attempts: non_neg_integer(),
          max_attempts: pos_integer(),
          base_delay_ms: non_neg_integer(),
          max_delay_ms: non_neg_integer(),
          retryable_errors: [atom()],
          circuit_open: boolean(),
          circuit_failure_count: non_neg_integer()
        }

  defstruct attempts: 0,
            max_attempts: 3,
            base_delay_ms: 1_000,
            max_delay_ms: 30_000,
            retryable_errors: [:model_loading, :timeout, :rate_limit],
            circuit_open: false,
            circuit_failure_count: 0

  @circuit_breaker_threshold 5
  @doc """
  Ejecuta una función con retry automático.

  ## Opciones

  - `:max_attempts` - Máximo de intentos (default: 3)
  - `:base_delay_ms` - Delay base en ms para backoff exponencial (default: 1000)
  - `:max_delay_ms` - Delay máximo entre intentos (default: 30000)
  - `:retry_on` - Lista de errores retryables

  ## Ejemplo

      retry_config = %Retry{max_attempts: 3}
      Retry.with_retry(retry_config, fn ->
        HuggingFaceChat.call(llm, messages)
      end)
  """
  @spec with_retry(t(), (-> any())) :: {:ok, any()} | {:error, term()}
  def with_retry(%__MODULE__{} = config, fun) when is_function(fun, 0) do
    if config.circuit_open do
      record_failure(config)
      {:error, :circuit_breaker_open}
    else
      do_retry(config, fun, config.attempts)
    end
  end

  @doc """
  Versión que lanza excepción en caso de error.
  """
  @spec with_retry!(t(), (-> any())) :: any() | no_return()
  def with_retry!(%__MODULE__{} = config, fun) do
    case with_retry(config, fun) do
      {:ok, result} -> result
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Configuración por defecto.
  """
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc """
  Configuración para producción (más agresiva).
  """
  @spec production() :: t()
  def production do
    %__MODULE__{
      max_attempts: 5,
      base_delay_ms: 2_000,
      max_delay_ms: 60_000,
      retryable_errors: [:model_loading, :timeout, :rate_limit, :connection_error]
    }
  end

  # ─────────────────────────────────────────────────────────────────
  # Private
  # ─────────────────────────────────────────────────────────────────

  defp do_retry(config, fun, attempts) do
    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        {:ok, fun.()}
      rescue
        err in LangChainError ->
          reason = extract_error_reason(err)
          classify_and_sleep(config, reason, attempts)

          if attempts < config.max_attempts,
            do: do_retry(config, fun, attempts + 1),
            else: {:error, reason}

        err ->
          {:error, Exception.message(err)}
      end

    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:alethea, :ai, :retry],
      %{
        attempts: attempts,
        duration: duration,
        success: match?({:ok, _}, result)
      },
      %{config: config.max_attempts}
    )

    result
  end

  defp classify_and_sleep(_config, _reason, attempts) when attempts >= 3, do: :ok

  defp classify_and_sleep(config, reason, attempts) do
    if retryable?(config, reason) do
      delay = calculate_delay(config, attempts)
      :timer.sleep(delay)
    else
      {:error, reason}
    end
  end

  defp retryable?(%__MODULE__{retryable_errors: list}, reason) do
    reason in list
  end

  defp calculate_delay(%__MODULE__{base_delay_ms: base, max_delay_ms: max}, attempts) do
    delay = (base * :math.pow(2, attempts - 1)) |> round()
    min(delay, max)
  end

  defp extract_error_reason(%LangChainError{message: msg}) do
    cond do
      String.contains?(msg, "model is loading") or String.contains?(msg, "503") -> :model_loading
      String.contains?(msg, "timeout") -> :timeout
      String.contains?(msg, "rate limit") -> :rate_limit
      String.contains?(msg, "connection") -> :connection_error
      true -> :unknown
    end
  end

  defp record_failure(%__MODULE__{} = config) do
    new_count = config.circuit_failure_count + 1

    if new_count >= @circuit_breaker_threshold do
      :telemetry.execute([:alethea, :ai, :circuit_breaker], %{event: :opened}, %{})
    end

    %{config | circuit_failure_count: new_count}
  end
end
