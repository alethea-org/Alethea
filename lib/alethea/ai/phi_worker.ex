defmodule Alethea.AI.PhiWorker do
  @moduledoc """
  Worker de alto nivel que orquesta la ejecución de la chain de conversación guiada.

  Es el último módulo antes de la llamada al modelo: vuelve a pasar el
  turno actual y el historial por `Alethea.AI.Sanitizer` (idempotente)
  para que nada sin sanitizar pueda salir aunque un caller omita ese
  paso. No agrega puntajes de emoción ni ningún otro dato clínico
  inferido al material que recibe el modelo.
  """
  @behaviour Alethea.AI.PhiWorkerBehaviour

  alias Alethea.AI.Chains.GuidedConversationChain
  alias Alethea.AI.Chains.RunningSummaryChain
  alias Alethea.AI.Sanitizer

  @impl true
  def process(%{message_id: message_id, sanitized_content: content, history: history}) do
    GuidedConversationChain.run(%{
      sanitized_content: Sanitizer.sanitize(content),
      history: Enum.map(history, &%{role: &1.role, content: Sanitizer.sanitize(&1.content)}),
      message_id: message_id
    })
  end

  @impl true
  def summarize(%{turns: turns} = request) do
    RunningSummaryChain.run(%{
      turns: Enum.map(turns, &%{role: &1.role, content: Sanitizer.sanitize(&1.content)}),
      previous_summary: sanitize_previous(Map.get(request, :previous_summary))
    })
  end

  defp sanitize_previous(previous) when is_binary(previous), do: Sanitizer.sanitize(previous)
  defp sanitize_previous(_none), do: nil
end
