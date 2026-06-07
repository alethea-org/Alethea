defmodule Alethea.AI.MockCase do
  @moduledoc """
  Test helper para usar mocks de AI en tests.

  ## Uso

      defmodule MyTest do
        use ExUnit.Case
        use Alethea.AI.MockCase

        test "uses mock" do
          mock_roberta([%{predictions: [%{label: "joy", score: 0.9}]}])
          # ...
        end
      end

  """

  import ExUnit.Assertions

  defmacro __using__(_opts) do
    quote do
      import Alethea.AI.MockCase

      setup do
        # Reset all AI mocks before each test
        [
          Alethea.AI.Mock.RoBERTa,
          Alethea.AI.Mock.Phi
        ]
        |> Enum.each(fn module ->
          if Code.ensure_loaded?(module) do
            try do
              GenServer.call(module, :reset)
            rescue
              _ -> :ok
            end
          end
        end)

        :ok
      end
    end
  end

  @doc """
  Configura respuesta mock de RoBERTa.
  """
  def mock_roberta(response) do
    if Code.ensure_loaded?(Alethea.AI.Mock.RoBERTa) do
      Alethea.AI.Mock.RoBERTa.set_response(response)
    end
  end

  @doc """
  Configura respuesta mock de error para RoBERTa.
  """
  def mock_roberta_error(error_type, message \\ "Mock error") do
    if Code.ensure_loaded?(Alethea.AI.Mock.RoBERTa) do
      Alethea.AI.Mock.RoBERTa.set_error(error_type, message)
    end
  end

  @doc """
  Configura respuesta mock de PhiWorker.
  """
  def mock_phi(response) do
    if Code.ensure_loaded?(Alethea.AI.Mock.Phi) do
      Alethea.AI.Mock.Phi.set_response(response)
    end
  end

  @doc """
  Configura respuesta mock de error para PhiWorker.
  """
  def mock_phi_error(error_type, message \\ "Mock error") do
    if Code.ensure_loaded?(Alethea.AI.Mock.Phi) do
      Alethea.AI.Mock.Phi.set_error(error_type, message)
    end
  end

  @doc """
  Verifica que se llamó al mock de RoBERTa con ciertos argumentos.
  """
  def assert_roberta_called(args) do
    calls = Alethea.AI.Mock.RoBERTa.get_calls()

    assert Enum.any?(calls, fn call -> matches_call?(call, args) end),
           "Expected RoBERTa mock to be called with #{inspect(args)}, but calls were #{inspect(calls, pretty: true)}"
  end

  @doc """
  Verifica que se llamó al mock de Phi con ciertos argumentos.
  """
  def assert_phi_called(args) do
    calls = Alethea.AI.Mock.Phi.get_calls()

    assert Enum.any?(calls, fn call -> matches_call?(call, args) end),
           "Expected Phi mock to be called with #{inspect(args)}, but calls were #{inspect(calls, pretty: true)}"
  end

  defp matches_call?(call, args) when is_map(args) do
    Enum.all?(args, fn {k, v} -> Map.get(call, k) == v end)
  end

  defp matches_call?(_, _), do: false
end
