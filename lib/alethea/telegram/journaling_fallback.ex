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

  # #393 S2 (design §6): closing/acknowledgement copy for the
  # three-question stretch limit — a separate, shared pair of lists.
  # Unlike `@variants`, none of these asks a question: they stand in
  # for a model reply that `TopicExploration.enforce/4` is replacing
  # at or after the limit, regardless of which guard reason (if any)
  # triggered the original fallback substitution.
  @closing_invitations [
    "Gracias por todo lo que me contaste sobre esto. Cuando quieras, puedes contarme otra cosa de tu día.",
    "Gracias por compartir todo esto conmigo. Cuando gustes, puedes contarme algo más de tu día."
  ]

  @acknowledgements [
    "Gracias, queda registrado.",
    "Gracias, lo anoté."
  ]

  @doc "Every fallback variant, in fixed order."
  @spec variants() :: [String.t()]
  def variants, do: @variants

  @doc "The fallback variant for the inbound message identified by `inbound_id`."
  @spec for_inbound(binary()) :: String.t()
  def for_inbound(inbound_id) when is_binary(inbound_id) do
    Enum.at(@variants, :erlang.phash2(inbound_id, length(@variants)))
  end

  @doc "Every closing invitation variant, in fixed order."
  @spec closing_invitations() :: [String.t()]
  def closing_invitations, do: @closing_invitations

  @doc "Every post-closing acknowledgement variant, in fixed order."
  @spec acknowledgements() :: [String.t()]
  def acknowledgements, do: @acknowledgements

  @doc """
  The closing invitation for the inbound message identified by
  `inbound_id` (design §3): substituted for a model question once the
  stretch reaches its question limit and no invitation has been sent
  yet for it.
  """
  @spec closing_for_inbound(binary()) :: String.t()
  def closing_for_inbound(inbound_id) when is_binary(inbound_id) do
    Enum.at(@closing_invitations, :erlang.phash2(inbound_id, length(@closing_invitations)))
  end

  @doc """
  The post-closing acknowledgement for the inbound message identified
  by `inbound_id` (design §3): substituted for a model question once
  the invitation has already been sent for this stretch.
  """
  @spec acknowledgement_for_inbound(binary()) :: String.t()
  def acknowledgement_for_inbound(inbound_id) when is_binary(inbound_id) do
    Enum.at(@acknowledgements, :erlang.phash2(inbound_id, length(@acknowledgements)))
  end
end
