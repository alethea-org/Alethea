defmodule Alethea.AI.PhiWorkerBehaviour do
  @moduledoc """
  Behaviour contract for the Phi worker used by the Telegram AI pipeline.

  The caller supplies material that is already sanitized: the current
  patient turn and the prior conversation turns with explicit roles.
  """

  @type turn :: %{role: :patient | :alethea, content: String.t()}

  @type request :: %{
          required(:message_id) => binary(),
          required(:sanitized_content) => String.t(),
          required(:history) => [turn()],
          optional(:summary) => String.t(),
          optional(:exploration_mode) => :open | :closing
        }

  @type summarize_request :: %{
          required(:turns) => [turn()],
          optional(:previous_summary) => String.t()
        }

  @callback process(request()) :: {:ok, map()} | {:error, term()}

  @callback summarize(summarize_request()) ::
              {:ok, %{summary: String.t(), truncated: boolean()}} | {:error, term()}
end
