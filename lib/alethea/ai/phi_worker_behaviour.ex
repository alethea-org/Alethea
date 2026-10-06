defmodule Alethea.AI.PhiWorkerBehaviour do
  @moduledoc """
  Behaviour contract for the Phi worker used by the Telegram AI pipeline.

  The caller supplies material that is already sanitized: the current
  patient turn and the prior conversation turns with explicit roles.
  """

  @type turn :: %{role: :patient | :alethea, content: String.t()}

  @type request :: %{
          message_id: binary(),
          sanitized_content: String.t(),
          history: [turn()]
        }

  @callback process(request()) :: {:ok, map()} | {:error, term()}
end
