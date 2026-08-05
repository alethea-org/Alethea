ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Alethea.Repo, :manual)

Mox.defmock(Alethea.AI.RoBERTaWorkerMock, for: Alethea.AI.RoBERTaWorkerBehavior)
Mox.defmock(Alethea.AI.SessionSummaryChainMock, for: Alethea.AI.Chains.ChainBehaviour)
Mox.defmock(Alethea.AI.WeeklySummaryChainMock, for: Alethea.AI.Chains.ChainBehaviour)
Mox.defmock(Alethea.AI.PhiWorkerMock, for: Alethea.AI.PhiWorkerBehaviour)
