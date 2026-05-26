ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Alethea.Repo, :manual)

Mox.defmock(Alethea.WhatsApp.ClientMock, for: Alethea.WhatsApp.ClientBehaviour)
Mox.defmock(Alethea.AI.PhiWorkerMock, for: Alethea.AI.PhiWorkerBehaviour)
