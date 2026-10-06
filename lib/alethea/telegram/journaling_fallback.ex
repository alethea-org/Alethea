defmodule Alethea.Telegram.JournalingFallback do
  @moduledoc """
  Neutral exploratory replies substituted when a generated journaling
  reply may not be shown to the patient (#392).

  Every variant acknowledges briefly and asks exactly one open question
  about the patient's own experience. None of them refers to what the
  patient wrote, so they are safe after any message that took the
  ordinary (non-crisis) path.

  The variant is chosen from the inbound message id, so the same inbound
  always maps to the same variant — stable across retries and tests —
  while consecutive inbounds vary.
  """

  @variants [
    "Gracias por contármelo. ¿Qué fue lo que más te quedó dando vueltas de eso?",
    "Gracias por escribirlo aquí. ¿Cómo viviste ese momento?",
    "Gracias por compartirlo. ¿Qué te gustaría dejar registrado sobre lo que pasó?",
    "Te leo con atención. ¿Qué sentiste mientras ocurría?"
  ]

  @doc "Every fallback variant, in fixed order."
  @spec variants() :: [String.t()]
  def variants, do: @variants

  @doc "The fallback variant for the inbound message identified by `inbound_id`."
  @spec for_inbound(binary()) :: String.t()
  def for_inbound(inbound_id) when is_binary(inbound_id) do
    Enum.at(@variants, :erlang.phash2(inbound_id, length(@variants)))
  end
end
