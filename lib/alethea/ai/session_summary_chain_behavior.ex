defmodule Alethea.AI.SessionSummaryChainBehavior do
  @callback run(list(String.t()), list(map())) :: {:ok, String.t()} | {:error, term()}
end
