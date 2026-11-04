defmodule Alethea.AI.TriggerMatcher.Disabled do
  @moduledoc """
  Reactive-trigger matcher for a deployment where the capability is
  switched off (#448).

  Production wires this module into the `:trigger_matcher` slot until a
  real adapter lands (#449). It never returns probabilities: the journaling
  reply is generated without any reactive trigger.
  """

  @behaviour Alethea.AI.TriggerMatcherBehaviour

  @impl true
  def match(_text, _candidates), do: {:error, :unavailable}
end
