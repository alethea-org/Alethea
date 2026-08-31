ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Alethea.Repo, :manual)

# Emotion analyzer slot is wired to Alethea.AI.EmotionAnalyzer.Fake in
# config/test.exs (issue #198) — deterministic, no Mox mock needed for
# the happy path. The EmotionAnalyzerBehaviourMock below is used by the
# failure-shape coverage (see EmotionAnalysisWorkerTest) where the Fake's
# fixed-shape success vector is insufficient.
Mox.defmock(Alethea.AI.EmotionAnalyzerBehaviourMock, for: Alethea.AI.EmotionAnalyzerBehaviour)
Mox.defmock(Alethea.AI.SessionSummaryChainMock, for: Alethea.AI.Chains.ChainBehaviour)
Mox.defmock(Alethea.AI.WeeklySummaryChainMock, for: Alethea.AI.Chains.ChainBehaviour)
Mox.defmock(Alethea.AI.PatternProposalChainMock, for: Alethea.AI.Chains.ChainBehaviour)
Mox.defmock(Alethea.AI.PhiWorkerMock, for: Alethea.AI.PhiWorkerBehaviour)
