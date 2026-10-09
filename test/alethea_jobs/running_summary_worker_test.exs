defmodule AletheaJobs.RunningSummaryWorkerTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.FoundationTestHelper
  import Alethea.RunningSummaryHelper
  import ExUnit.CaptureLog
  import Mox

  alias Alethea.Accounts
  alias Alethea.Accounts.AuditLog
  alias Alethea.AI.PhiWorkerMock
  alias Alethea.Clinical
  alias Alethea.Clinical.Message
  alias Alethea.Clinical.RunningSummary
  alias Alethea.Clinical.RunningSummary.Snapshot
  alias Alethea.Encryption.PatientVault
  alias AletheaJobs.RunningSummaryWorker

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    professional = legacy_professional_fixture()
    patient = legacy_patient_fixture(professional)
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)
    %{patient: patient, dek: dek}
  end

  defp args(patient), do: %{"patient_id" => patient.id}
  defp run(patient), do: perform_job(RunningSummaryWorker, args(patient))
  defp ok_summary, do: {:ok, %{summary: valid_summary(), truncated: false}}
  defp row(patient), do: Repo.get_by(Snapshot, patient_id: patient.id)

  defp stub_summary(pid \\ self()) do
    expect(PhiWorkerMock, :summarize, fn request ->
      send(pid, {:request, request})
      ok_summary()
    end)
  end

  defp requested do
    assert_received {:request, request}
    request
  end

  defp other_jobs_count do
    Repo.aggregate(from(j in Oban.Job, where: j.worker != ^inspect(RunningSummaryWorker)), :count)
  end

  describe "not due and window" do
    test "fewer than ten pending inbounds is a no-op without calling the model", ctx do
      seed(ctx.patient, ctx.dek, 1..9)
      expect(PhiWorkerMock, :summarize, 0, fn _ -> ok_summary() end)

      assert :ok = run(ctx.patient)
      assert row(ctx.patient) == nil
    end

    test "first build targets the latest 10-aligned inbound; window equals the reply history",
         ctx do
      [_ | _] = inbounds = seed(ctx.patient, ctx.dek, 1..25)
      target = Enum.at(inbounds, 19)
      {:ok, before} = Clinical.list_conversation_turns(ctx.patient, target, 39)
      stub_summary()

      assert :ok = run(ctx.patient)

      request = requested()
      assert Map.keys(request) == [:turns]
      assert request.turns == before ++ [%{role: :patient, content: "paciente 20"}]
      assert length(request.turns) == 39
      assert row(ctx.patient).covered_inbound_count == 20
      assert row(ctx.patient).covered_through_message_id == target.id
    end

    test "window is capped at 40 turns and keeps crisis_bypass replies in order", ctx do
      [_ | _] = inbounds = seed(ctx.patient, ctx.dek, 1..30)
      turn(ctx.patient, ctx.dek, "outbound", "crisis_bypass", "alethea crisis", 41)
      target = Enum.at(inbounds, 29)
      {:ok, before} = Clinical.list_conversation_turns(ctx.patient, target, 39)
      stub_summary()

      assert :ok = run(ctx.patient)

      request = requested()
      assert length(request.turns) == 40
      assert request.turns == before ++ [%{role: :patient, content: "paciente 30"}]
      assert %{role: :alethea, content: "alethea crisis"} in request.turns
    end

    test "a superseded reply is withheld from the model; sent and pending ones are supplied",
         ctx do
      seed(ctx.patient, ctx.dek, 1..10)

      for {state, text, offset} <- [
            {"superseded", "no enviado", 5},
            {"sent", "enviado", 7},
            {"pending", "pendiente", 9}
          ] do
        reply = turn(ctx.patient, ctx.dek, "outbound", "elicited", text, offset)

        Repo.update_all(from(m in Message, where: m.id == ^reply.id),
          set: [delivery_state: state]
        )
      end

      stub_summary()
      assert :ok = run(ctx.patient)

      contents = Enum.map(requested().turns, & &1.content)
      assert "enviado" in contents
      assert "pendiente" in contents
      refute "no enviado" in contents
    end

    test "incremental build starts at the anchor second and carries the previous summary",
         ctx do
      [_ | _] = inbounds = seed(ctx.patient, ctx.dek, 1..20)
      put_row(ctx.patient, ctx.dek, "Hechos previos: nada", :first, 0, 10, Enum.at(inbounds, 9))
      stub_summary()

      assert :ok = run(ctx.patient)

      request = requested()
      assert request.previous_summary == "Hechos previos: nada"
      [first | _] = request.turns
      assert first == %{role: :patient, content: "paciente 10"}
      assert List.last(request.turns) == %{role: :patient, content: "paciente 20"}
      assert length(request.turns) == 2 * 10 + 1
      assert row(ctx.patient).covered_inbound_count == 20
    end
  end

  describe "model input" do
    test "carries only role-tagged sanitized turns and a sanitized previous summary", ctx do
      [_ | _] = inbounds = seed(ctx.patient, ctx.dek, 1..9)
      turn(ctx.patient, ctx.dek, "inbound", "spontaneous", "mi mail es ana@example.com", 19)
      put_row(ctx.patient, ctx.dek, "- llamar al +56 9 1234 5678", :first, 0, 3, hd(inbounds))
      seed(ctx.patient, ctx.dek, 11..14)
      stub_summary()

      assert :ok = run(ctx.patient)

      request = requested()
      assert Enum.sort(Map.keys(request)) == [:previous_summary, :turns]
      assert Enum.all?(request.turns, &(Map.keys(&1) |> Enum.sort() == [:content, :role]))
      assert Enum.any?(request.turns, &(&1.content =~ "[REDACTED_EMAIL]"))
      refute inspect(request) =~ "ana@example.com"
      assert request.previous_summary =~ "[REDACTED_PHONE]"
      refute request.previous_summary =~ "1234"
    end
  end

  describe "failures use atoms only" do
    setup ctx do
      [_ | _] = inbounds = seed(ctx.patient, ctx.dek, 1..10)
      Map.put(ctx, :inbounds, inbounds)
    end

    test "model error, invalid summary, truncated summary", ctx do
      expect(PhiWorkerMock, :summarize, fn _ -> {:error, "secret: paciente 3 dijo algo"} end)
      assert {:error, :generation_failed} = run(ctx.patient)

      expect(PhiWorkerMock, :summarize, fn _ ->
        {:ok, %{summary: "texto libre", truncated: false}}
      end)

      assert {:error, :invalid_summary} = run(ctx.patient)

      expect(PhiWorkerMock, :summarize, fn _ ->
        {:ok, %{summary: valid_summary(), truncated: true}}
      end)

      assert {:error, :invalid_summary} = run(ctx.patient)

      expect(PhiWorkerMock, :summarize, fn _ -> raise "boom paciente 3" end)
      assert {:error, :generation_failed} = run(ctx.patient)
      assert row(ctx.patient) == nil
    end

    test "a failing write is :persist_failed", ctx do
      target = List.last(ctx.inbounds)

      expect(PhiWorkerMock, :summarize, fn _ ->
        Repo.delete_all(from(m in Message, where: m.id == ^target.id))
        ok_summary()
      end)

      assert {:error, :persist_failed} = run(ctx.patient)
      assert row(ctx.patient) == nil
    end

    test "a concurrent winner makes the job cancel as stale and keeps its row", ctx do
      target = List.last(ctx.inbounds)

      expect(PhiWorkerMock, :summarize, fn _ ->
        put_row(ctx.patient, ctx.dek, "ganador", :first, 0, 10, target)
        ok_summary()
      end)

      assert {:cancel, :stale} = run(ctx.patient)
      assert {:ok, "ganador"} = RunningSummary.load_usable(ctx.patient)
    end

    test "oban_jobs.errors, logs and telemetry never carry text, hash or DEK", ctx do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "rs-#{inspect(ref)}",
        [[:oban, :job, :stop], [:oban, :job, :exception]],
        fn event, measure, meta, _ -> send(test_pid, {:telemetry, event, measure, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("rs-#{inspect(ref)}") end)

      expect(PhiWorkerMock, :summarize, fn _ -> {:error, "secret: paciente 3 dijo algo"} end)
      {:ok, _} = Oban.insert(RunningSummaryWorker.new(args(ctx.patient)))

      log =
        capture_log(fn ->
          assert %{failure: 1} = Oban.drain_queue(queue: :running_summary)
        end)

      assert_received {:telemetry, [:oban, :job, :exception], _, _} = event

      [%Oban.Job{errors: [%{"error" => error}]}] =
        Repo.all(Oban.Job |> where(worker: ^inspect(RunningSummaryWorker)))

      assert error =~ ":generation_failed"

      secrets = [
        "secret",
        "paciente 3",
        "Hechos",
        Base.encode64(ctx.dek),
        Base.encode16(ctx.dek, case: :lower),
        Base.encode16(ctx.dek),
        inspect(ctx.dek)
      ]

      for haystack <- [error, log, inspect(event)], secret <- secrets do
        refute haystack =~ secret
      end

      refute log =~ ~r/\b[0-9a-f]{64}\b/

      # The failure is correlated through `oban_jobs` (job id + atom error),
      # so the log carries the reason only, never the patient identifier.
      assert log =~ "RunningSummaryWorker: failed (reason=generation_failed)"
      refute log =~ to_string(ctx.patient.id)
    end
  end

  describe "audit, reset and backlog" do
    test "unwraps the DEK once per run with the generation reason", ctx do
      seed(ctx.patient, ctx.dek, 1..10)
      stub_summary()
      assert :ok = run(ctx.patient)

      reasons =
        AuditLog
        |> where([a], a.resource_id == ^ctx.patient.id and a.action == "PII_DECRYPT")
        |> Repo.all()
        |> Enum.map(& &1.details["reason"])

      assert reasons == ["running_summary_generation"]
    end

    test "fewer inbounds than covered resets the row and rebuilds without the old text", ctx do
      [_ | _] = inbounds = seed(ctx.patient, ctx.dek, 1..12)
      put_row(ctx.patient, ctx.dek, "ANTIGUO-HECHO", :first, 0, 20, Enum.at(inbounds, 9))
      stub_summary()

      assert :ok = run(ctx.patient)

      request = requested()
      refute Map.has_key?(request, :previous_summary)
      refute inspect(request) =~ "ANTIGUO"
      assert row(ctx.patient).covered_inbound_count == 10
      assert row(ctx.patient).covered_through_message_id == Enum.at(inbounds, 9).id
    end

    test "declares finite attempts and per-patient uniqueness over live states" do
      opts = RunningSummaryWorker.__opts__()
      assert opts[:queue] == :running_summary
      assert opts[:max_attempts] == 3
      assert opts[:unique][:keys] == [:patient_id]
      assert opts[:unique][:states] == [:available, :scheduled, :retryable]
    end

    test "a backlog of twenty chains the next batch; no other job is enqueued", ctx do
      [_ | _] = inbounds = seed(ctx.patient, ctx.dek, 1..30)
      put_row(ctx.patient, ctx.dek, valid_summary(), :first, 0, 10, Enum.at(inbounds, 9))
      before = other_jobs_count()
      expect(PhiWorkerMock, :summarize, 2, fn _ -> ok_summary() end)

      {:ok, _} = Oban.insert(RunningSummaryWorker.new(args(ctx.patient)))

      assert %{success: 2, failure: 0} =
               Oban.drain_queue(queue: :running_summary, with_recursion: true)

      assert row(ctx.patient).covered_inbound_count == 30
      assert other_jobs_count() == before
    end

    test "a discarded job does not block the next trigger", ctx do
      seed(ctx.patient, ctx.dek, 1..10)
      {:ok, job} = Oban.insert(RunningSummaryWorker.new(args(ctx.patient)))
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "discarded"])

      assert :ok = RunningSummary.schedule_if_due(ctx.patient.id, "abcd1234")
      assert [_new] = all_enqueued(worker: RunningSummaryWorker)
    end
  end

  describe "storage opacity at the write path" do
    test "the stored column is ciphertext that only the patient DEK opens", ctx do
      seed(ctx.patient, ctx.dek, 1..10)
      stub_summary()
      assert :ok = run(ctx.patient)

      %{rows: [[raw]]} =
        Repo.query!("SELECT encrypted_summary FROM running_summaries WHERE patient_id = $1", [
          Ecto.UUID.dump!(ctx.patient.id)
        ])

      plain = valid_summary()
      assert raw != plain

      for fragment <- ["Hechos", "Preguntas", "hermana", "dormiste", "Alethea hizo"] do
        refute raw =~ fragment
      end

      assert {:ok, ^plain} = PatientVault.decrypt(raw, ctx.dek)
      refute match?({:ok, _}, PatientVault.decrypt(raw, :crypto.strong_rand_bytes(32)))
    end
  end
end
