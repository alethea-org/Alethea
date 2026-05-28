defmodule Alethea.AI.PhiWorkerBehaviour do
  @moduledoc """
  Behaviour contract for the Phi worker used by the WhatsApp AI pipeline.
  """

  @callback process(%{message_id: binary(), raw_content: String.t(), patient_context: String.t()}) ::
              map()
end
