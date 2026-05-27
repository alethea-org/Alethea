defmodule Alethea.AI.WeeklySummaryChainBehavior do
  @callback run(list(Alethea.Clinical.Summary.t()), list(map())) :: {:ok, String.t()} | {:error, term()}
end
