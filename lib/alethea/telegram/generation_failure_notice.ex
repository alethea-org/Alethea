defmodule Alethea.Telegram.GenerationFailureNotice do
  @moduledoc """
  The single fixed notice a Telegram patient receives when the journaling
  reply's generation retries are exhausted (#395).

  The notice is transparent about the service being unavailable and it
  never invents clinical content: it is a constant string, independent of
  what the patient wrote. It says the patient's message was recorded ONLY
  in the `recorded?: true` variant, which callers may select only after
  the inbounds it covers are confirmed persisted rows. The default
  (`text/0`) claims nothing, so a caller that cannot confirm persistence
  can never assert recording by accident.

  `model_version/0` is the discriminator persisted on the reply's
  `Alethea.AI.Diagnosis` row: it separates a generation failure — the
  retries ran out before the model produced anything — from a model
  output and from the outbound transport dead-letter path.
  """

  @recorded "No pude generar una respuesta en este momento: el servicio de respuestas no está disponible. Tu mensaje quedó registrado y tu terapeuta podrá verlo. Puedes escribirme de nuevo más tarde."

  @unrecorded "No pude generar una respuesta en este momento: el servicio de respuestas no está disponible. No pude guardar tu mensaje de forma confirmada. Por favor, inténtalo de nuevo más tarde."

  @model_version "generation-unavailable"

  @doc """
  The fixed notice text.

  `recorded?: true` selects the variant that asserts the message was
  recorded; it must only be used when persistence of the covered
  inbounds has been confirmed. Any other option (or none) selects the
  variant that makes no recording claim.
  """
  @spec text() :: String.t()
  @spec text(keyword()) :: String.t()
  def text(opts \\ []) do
    if Keyword.get(opts, :recorded?, false), do: @recorded, else: @unrecorded
  end

  @doc """
  The `model_version` recorded on the failure's diagnosis row.
  """
  @spec model_version() :: String.t()
  def model_version, do: @model_version
end
