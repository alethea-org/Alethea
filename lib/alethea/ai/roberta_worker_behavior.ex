defmodule Alethea.AI.RoBERTaWorkerBehavior do
  @callback analyze_batch(list(String.t())) :: list(map())
end
