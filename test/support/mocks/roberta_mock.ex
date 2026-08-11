defmodule Alethea.AI.Mock.RoBERTa do
  @moduledoc """
  Legacy RoBERTa test mock retained until the follow-up support cleanup.
  """

  use GenServer
  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: Keyword.get(opts, :name, __MODULE__))
  end

  def set_response(response) when is_list(response) or is_map(response) do
    GenServer.call(__MODULE__, {:set_response, response})
  end

  def set_responses(responses) when is_list(responses) do
    GenServer.call(__MODULE__, {:set_responses, responses})
  end

  def set_error(error_type, message \\ "Mock error") do
    GenServer.call(__MODULE__, {:set_error, error_type, message})
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  def get_calls do
    GenServer.call(__MODULE__, :get_calls)
  end

  def call_count do
    length(get_calls())
  end

  def was_called? do
    call_count() > 0
  end

  def analyze_batch(texts) do
    GenServer.call(__MODULE__, {:analyze_batch, texts})
  end

  # Server Implementation

  def init(_opts) do
    {:ok, %{response: nil, error: nil, sequence: [], calls: []}}
  end

  def handle_call({:set_response, response}, _from, state) do
    {:reply, :ok, %{state | response: response, error: nil, sequence: []}}
  end

  def handle_call({:set_responses, responses}, _from, _state) do
    {:reply, :ok, %{response: nil, error: nil, sequence: responses, calls: []}}
  end

  def handle_call({:set_error, error_type, message}, _from, state) do
    error = %{type: error_type, message: message}
    {:reply, :ok, %{state | error: error, response: nil, sequence: []}}
  end

  def handle_call(:get_calls, _from, state) do
    {:reply, Enum.reverse(state.calls), state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{response: nil, error: nil, sequence: [], calls: []}}
  end

  def handle_call({:analyze_batch, texts}, _from, state) do
    new_calls = [
      %{function: :analyze_batch, args: texts, timestamp: DateTime.utc_now()} | state.calls
    ]

    # Handle sequence - keep returning last element if sequence exhausted
    case state do
      %{sequence: [last]} ->
        # Only one element left - return it and keep it
        {:reply, last, %{state | calls: new_calls}}

      %{sequence: [head | tail]} ->
        {:reply, head, %{state | sequence: tail, calls: new_calls}}

      %{response: response, error: nil} ->
        {:reply, response, %{state | calls: new_calls}}

      %{error: error} ->
        {:reply, {:error, error}, %{state | calls: new_calls}}

      _ ->
        {:reply, {:error, :no_response_configured}, %{state | calls: new_calls}}
    end
  end
end
