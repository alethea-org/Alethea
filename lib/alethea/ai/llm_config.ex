defmodule Alethea.AI.LLMConfig do
  @moduledoc """
  Configuración centralizada para todos los modelos LLM.

  Elimina la duplicación de código de configuración entre chains.
  Provee defaults seguros y validación de parámetros.

  ## Endpoint resolution

  A chain's endpoint (and API key) comes from explicit overrides, then
  from its own first-level options, then from its own nested
  `<provider>: [...]` settings, then from the global
  `config :alethea, Alethea.AI.LLMConfig, <provider>: [...]`, then from a
  provider default. The `:local` default (`http://localhost:11434`)
  exists for development and tests only: in production there is no local
  default, so a chain whose provider has no configured endpoint resolves
  to `endpoint_url: nil` and `build_llm/1` returns `{:error, _}` ("not
  configured") instead of calling localhost (issue #402). A blank endpoint
  (empty or whitespace) is not a value: it falls through to the next
  source, and `build_llm/1` rejects it as "not configured".

  ## Uso

      alias Alethea.AI.LLMConfig

      # Obtener configuración para una chain específica
      config = LLMConfig.get(:guided_conversation)
      llm = LLMConfig.build_llm(config)

      # Con retry
      config = LLMConfig.get_with_retry(:guided_conversation)
      LLMConfig.run_with_retry(config, fn -> chain.run(params) end)
  """

  alias Alethea.AI.ChatModels.OllamaChat
  alias Alethea.AI.Retry
  alias LangChain.ChatModels.ChatOpenAI

  @type provider :: :local | :cloud
  @type chain_name ::
          :guided_conversation
          | :session_summary
          | :weekly_summary
          | :weekly_report
          | :pattern_proposal
          | :consultation_synthesis
          | :consultation_hypothesis
          | :functional_analysis_draft

  @type config :: %__MODULE__.Config{
          provider: provider(),
          model: String.t(),
          api_key: String.t() | nil,
          endpoint_url: String.t() | nil,
          temperature: float(),
          max_tokens: pos_integer(),
          timeout: pos_integer(),
          stream: boolean(),
          retry: Retry.t()
        }

  defmodule Config do
    @moduledoc false
    @enforce_keys [:provider, :model, :api_key, :endpoint_url]
    defstruct [
      :provider,
      :model,
      :api_key,
      :endpoint_url,
      temperature: 0.0,
      max_tokens: 512,
      timeout: 60_000,
      stream: false,
      retry: %Retry{}
    ]

    @type t :: %__MODULE__{
            provider: Alethea.AI.LLMConfig.provider(),
            model: String.t(),
            api_key: String.t() | nil,
            endpoint_url: String.t() | nil,
            temperature: float(),
            max_tokens: pos_integer(),
            timeout: pos_integer(),
            stream: boolean(),
            retry: Retry.t()
          }
  end

  @doc """
  Obtiene la configuración para una chain específica.
  """
  @spec get(chain_name(), keyword()) :: config()
  def get(chain_name, overrides \\ []) when is_atom(chain_name) do
    chain_config =
      Application.get_env(:alethea, chain_module(chain_name), [])
      |> Keyword.merge(Application.get_env(:alethea, chain_name, []))

    global_config = Application.get_env(:alethea, __MODULE__, [])

    provider =
      Keyword.get(overrides, :provider) ||
        Keyword.get(chain_config, :provider) ||
        Keyword.get(global_config, :provider, :local)

    # The chain's nested provider settings are consulted before the global
    # ones. They are kept apart rather than concatenated: `Keyword.get/2`
    # returns the first match, and an endpoint may be spelled `:endpoint_url`
    # on one side and `:endpoint` on the other.
    chain_provider_config = Keyword.get(chain_config, provider, [])
    global_provider_config = Keyword.get(global_config, provider, [])

    defaults = Keyword.get(global_config, :defaults, [])

    api_key =
      resolve_api_key(
        Keyword.get(overrides, :api_key) ||
          Keyword.get(chain_config, :api_key) ||
          Keyword.get(chain_provider_config, :api_key) ||
          Keyword.get(global_provider_config, :api_key)
      )

    # Each source goes through `resolve_endpoint_url/1` on its own, so a
    # blank value falls through to the next source instead of masking it.
    endpoint_url =
      resolve_endpoint_url(Keyword.get(overrides, :endpoint_url)) ||
        resolve_endpoint_url(Keyword.get(chain_config, :endpoint_url)) ||
        resolve_endpoint_url(Keyword.get(chain_config, :endpoint)) ||
        resolve_endpoint_url(Keyword.get(chain_provider_config, :endpoint_url)) ||
        resolve_endpoint_url(Keyword.get(chain_provider_config, :endpoint)) ||
        resolve_endpoint_url(Keyword.get(global_provider_config, :endpoint_url)) ||
        resolve_endpoint_url(Keyword.get(global_provider_config, :endpoint)) ||
        default_endpoint(provider)

    retry = build_retry_config(global_config, chain_config, overrides)

    %Config{
      provider: provider,
      model:
        Keyword.get(overrides, :model) ||
          Keyword.get(chain_config, :model) ||
          Keyword.get(defaults, :model, default_model(provider)),
      api_key: api_key,
      endpoint_url: endpoint_url,
      temperature:
        Keyword.get(overrides, :temperature) ||
          Keyword.get(chain_config, :temperature) ||
          Keyword.get(defaults, :temperature, 0.0),
      max_tokens:
        Keyword.get(overrides, :max_tokens) ||
          Keyword.get(chain_config, :max_tokens) ||
          Keyword.get(defaults, :max_tokens, 512),
      timeout:
        Keyword.get(overrides, :timeout) ||
          Keyword.get(chain_config, :timeout) ||
          Keyword.get(defaults, :timeout, 60_000),
      stream:
        Keyword.get(overrides, :stream) ||
          Keyword.get(chain_config, :stream) ||
          Keyword.get(defaults, :stream, false),
      retry: retry
    }
  end

  @doc """
  Construye un LLM instance listo para usar.
  """
  @spec build_llm(config()) :: {:ok, OllamaChat.t() | ChatOpenAI.t()} | {:error, String.t()}
  def build_llm(%Config{provider: provider, endpoint_url: endpoint_url} = config) do
    # A blank endpoint is not an endpoint: the adapters would either fall
    # back to their own localhost default or request a relative path.
    if resolve_endpoint_url(endpoint_url) do
      build_chat_model(config)
    else
      {:error, "LLM endpoint for the #{inspect(provider)} provider is not configured"}
    end
  end

  defp build_chat_model(%Config{provider: :local} = config) do
    {:ok,
     OllamaChat.new!(%{
       model: config.model,
       endpoint_url: config.endpoint_url,
       temperature: config.temperature,
       max_tokens: config.max_tokens,
       stream: config.stream,
       receive_timeout: config.timeout
     })}
  end

  defp build_chat_model(%Config{provider: :cloud} = config) do
    if usable_api_key?(config.api_key) do
      {:ok,
       ChatOpenAI.new!(%{
         model: config.model,
         api_key: config.api_key,
         endpoint: config.endpoint_url,
         temperature: config.temperature,
         max_tokens: config.max_tokens,
         stream: config.stream,
         receive_timeout: config.timeout
       })}
    else
      {:error, "API key required for cloud provider"}
    end
  end

  @doc """
  Construye un LLM instance o lanza excepción.
  """
  @spec build_llm!(config()) :: OllamaChat.t() | ChatOpenAI.t() | no_return()
  def build_llm!(%Config{} = config) do
    case build_llm(config) do
      {:ok, llm} -> llm
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc """
  Obtiene la config y construye el LLM en un solo paso.
  """
  @spec get_and_build(chain_name(), keyword()) ::
          {:ok, config(), OllamaChat.t() | ChatOpenAI.t()} | {:error, String.t()}
  def get_and_build(chain_name, overrides \\ []) do
    config = get(chain_name, overrides)

    case build_llm(config) do
      {:ok, llm} -> {:ok, config, llm}
      {:error, _} = error -> error
    end
  end

  @doc """
  Ejecuta una función con retry usando la config de la chain.
  """
  @spec run_with_retry(config(), (-> any())) :: {:ok, any()} | {:error, term()}
  def run_with_retry(%Config{} = config, fun) when is_function(fun, 0) do
    Retry.with_retry(config.retry, fun)
  end

  @doc """
  Obtiene config con retry habilitado.
  """
  @spec get_with_retry(chain_name(), keyword()) :: config()
  def get_with_retry(chain_name, overrides \\ []) do
    get(chain_name, [retry_enabled: true] ++ overrides)
  end

  # ─────────────────────────────────────────────────────────────────
  # Private
  # ─────────────────────────────────────────────────────────────────

  # An empty or blank string is not a credential.
  defp usable_api_key?(api_key), do: is_binary(api_key) and String.trim(api_key) != ""

  defp resolve_api_key(nil), do: nil

  # A blank key is no key: it must not pass as a credential.
  defp resolve_api_key(api_key) when is_binary(api_key) do
    if String.trim(api_key) == "", do: nil, else: api_key
  end

  defp resolve_api_key({:system, env_var}) when is_binary(env_var),
    do: resolve_api_key(System.get_env(env_var))

  # A blank endpoint is no endpoint: it must not pass as configured.
  defp resolve_endpoint_url(endpoint_url) when is_binary(endpoint_url) do
    if String.trim(endpoint_url) == "", do: nil, else: endpoint_url
  end

  defp resolve_endpoint_url(_endpoint_url), do: nil

  # The localhost default serves development and tests. Production has no
  # local default: an unconfigured endpoint stays `nil` ("not configured").
  defp default_endpoint(:local) do
    if Application.get_env(:alethea, :env) == :prod, do: nil, else: "http://localhost:11434"
  end

  defp default_endpoint(:cloud), do: "https://api.openai.com/v1/"

  defp default_model(:local), do: "phi4-mini"
  defp default_model(:cloud), do: "gpt-4o-mini"

  defp chain_module(:guided_conversation), do: Alethea.AI.Chains.GuidedConversationChain
  defp chain_module(:session_summary), do: Alethea.AI.Chains.SessionSummaryChain
  defp chain_module(:weekly_summary), do: Alethea.AI.Chains.WeeklySummaryChain
  defp chain_module(:weekly_report), do: Alethea.AI.Chains.WeeklyReportChain
  defp chain_module(:pattern_proposal), do: Alethea.AI.Chains.PatternProposalChain
  defp chain_module(:consultation_synthesis), do: Alethea.AI.Chains.ClinicalConsultationChain
  defp chain_module(:consultation_hypothesis), do: Alethea.AI.Chains.ClinicalHypothesisChain

  defp chain_module(:functional_analysis_draft),
    do: Alethea.AI.Chains.FunctionalAnalysisDraftChain

  defp build_retry_config(global, chain, overrides) do
    retry_enabled =
      Keyword.get(overrides, :retry_enabled, false) ||
        Keyword.get(chain, :retry_enabled, false) ||
        Keyword.get(global, :retry_enabled, false)

    if retry_enabled do
      %Retry{
        max_attempts:
          Keyword.get(overrides, :retry_max_attempts) ||
            Keyword.get(chain, :retry_max_attempts) ||
            Keyword.get(global, :retry_max_attempts, 3),
        base_delay_ms:
          Keyword.get(overrides, :retry_base_delay_ms) ||
            Keyword.get(chain, :retry_base_delay_ms) ||
            Keyword.get(global, :retry_base_delay_ms, 1_000),
        max_delay_ms:
          Keyword.get(overrides, :retry_max_delay_ms) ||
            Keyword.get(chain, :retry_max_delay_ms) ||
            Keyword.get(global, :retry_max_delay_ms, 30_000)
      }
    else
      %Retry{max_attempts: 1}
    end
  end
end
