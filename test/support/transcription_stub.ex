defmodule Alethea.TranscriptionStub do
  @moduledoc """
  Test-only `Alethea.AI.Whisper` adapter whose result each test sets.

      Alethea.TranscriptionStub.install(%{text: "...", segments: [...]})
      Alethea.TranscriptionStub.install({:error, :timeout})

  `install/1` points `:ai_whisper` at this module for the current test and
  restores the previous adapter on exit (tests using it must be `async: false`).
  Every call sends `{:transcription_stub_called, audio, opts}` to the calling
  process so tests can assert what reached the provider.
  """
  use Alethea.AI.Whisper

  import ExUnit.Callbacks, only: [on_exit: 1]

  @result_key :transcription_stub_result

  @doc "Wires the stub into `:ai_whisper` returning `result` (a map or `{:error, term}`)."
  def install(result) do
    previous_adapter = Application.fetch_env(:alethea, :ai_whisper)
    Application.put_env(:alethea, :ai_whisper, __MODULE__)
    set_result(result)

    on_exit(fn ->
      Application.delete_env(:alethea, @result_key)

      case previous_adapter do
        {:ok, adapter} -> Application.put_env(:alethea, :ai_whisper, adapter)
        :error -> Application.delete_env(:alethea, :ai_whisper)
      end
    end)

    :ok
  end

  @doc "Changes the result returned by later calls."
  def set_result(result), do: Application.put_env(:alethea, @result_key, result)

  @impl true
  def transcribe(audio, opts) do
    send(self(), {:transcription_stub_called, audio, opts})

    case Application.get_env(:alethea, @result_key) do
      {:error, _reason} = error -> error
      %{} = transcription -> {:ok, transcription}
      nil -> {:ok, %{text: "", language: nil, duration: nil, segments: []}}
    end
  end
end
