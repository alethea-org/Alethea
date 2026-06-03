defmodule Alethea.AI.Chains.ChainBehaviour do
  @moduledoc false

  @type chain_params :: %{optional(atom()) => any()} | list()
  @type chain_result :: {:ok, map()} | {:error, term()}

  @callback run(params :: chain_params()) :: chain_result()
  @callback run(params :: list(), scores :: list()) :: chain_result()
  @callback run!(params :: chain_params()) :: map() | no_return()
  @callback suggested_system_prompt() :: String.t()
  @callback suggested_max_tokens() :: pos_integer()
  @callback supported_providers() :: list(atom())

  @optional_callbacks [
    run!: 1,
    run: 2,
    suggested_system_prompt: 0,
    suggested_max_tokens: 0,
    supported_providers: 0
  ]
end
