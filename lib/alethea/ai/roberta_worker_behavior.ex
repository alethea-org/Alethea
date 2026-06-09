defmodule Alethea.AI.RoBERTaWorkerBehavior do
  @callback analyze_batch(list(String.t())) :: list(map())
  @callback analyze_batch_per_message(list(String.t())) :: list(list(map()))
end
