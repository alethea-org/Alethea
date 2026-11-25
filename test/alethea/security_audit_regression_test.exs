defmodule Alethea.SecurityAuditRegressionTest do
  @moduledoc """
  Regression probes from the independent verification of the security
  audit run-1 fixes: billing entitlement matrix (S6) and sealed Telegram
  job args (S4).
  """
  use Alethea.DataCase, async: false
  import Ecto.Query
  alias Alethea.{Billing, Repo}
  alias Alethea.Billing.Subscription
  alias Alethea.Jobs.{TelegramOutboundWorker, TelegramMessageWorker}
  alias Alethea.Telegram.JobPayload

  defp pro do
    {:ok, p} =
      Alethea.Accounts.create_professional(%{
        email: "P#{System.unique_integer([:positive])}@X.org",
        full_name: "P",
        password: "password-123456"
      })

    p
  end

  defp sub(p, attrs) do
    %Subscription{
      professional_id: p.id,
      paddle_subscription_id: "s#{System.unique_integer([:positive])}",
      last_event_occurred_at: DateTime.utc_now()
    }
    |> Map.merge(attrs)
    |> Repo.insert!()
  end

  describe "entitlement requires a configured price (S6)" do
    setup do
      old = Application.get_env(:alethea, Billing, [])

      Application.put_env(
        :alethea,
        Billing,
        Keyword.merge(old, enabled: true, price_ids: ["pri_ok"])
      )

      on_exit(fn -> Application.put_env(:alethea, Billing, old) end)
    end

    test "status and price matrix" do
      future = DateTime.add(DateTime.utc_now(), 3600) |> DateTime.truncate(:second)
      past = DateTime.add(DateTime.utc_now(), -3600) |> DateTime.truncate(:second)

      cases = [
        {%{status: "active", price_id: nil}, false},
        {%{status: "active", price_id: "pri_other"}, false},
        {%{status: "active", price_id: "pri_ok"}, true},
        {%{status: "past_due", price_id: "pri_ok"}, true},
        {%{status: "past_due", price_id: "pri_other"}, false},
        {%{status: "trialing", price_id: "pri_ok"}, true},
        {%{status: "canceled", price_id: "pri_ok", current_period_ends_at: future}, true},
        {%{status: "canceled", price_id: "pri_ok", current_period_ends_at: past}, false},
        {%{status: "canceled", price_id: "pri_other", current_period_ends_at: future}, false},
        {%{status: "canceled", price_id: "pri_ok", current_period_ends_at: nil}, false},
        {%{status: "paused", price_id: "pri_ok"}, false}
      ]

      for {attrs, expected} <- cases do
        p = pro()
        sub(p, attrs)
        assert Billing.entitled?(p) == expected, inspect(attrs)
      end

      assert Billing.entitled?(pro()) == false
    end
  end

  describe "Telegram job args are sealed (S4)" do
    defp raw_args(id),
      do:
        Repo.one!(from j in "oban_jobs", where: j.id == ^id, select: fragment("?::text", j.args))

    test "outbound sealed for atom & string keys, reschedule not double-sealed" do
      for args <- [
            %{"chat_id" => 4_242_424_242, "body" => "SECRETBODY", "chat_id_hash" => "h"},
            %{chat_id: 4_242_424_242, body: "SECRETBODY", chat_id_hash: "h"}
          ] do
        {:ok, job} = args |> TelegramOutboundWorker.new() |> Oban.insert()
        raw = raw_args(job.id)
        refute raw =~ "SECRETBODY"
        refute raw =~ "4242424242"
        reloaded = Repo.get!(Oban.Job, job.id)
        assert JobPayload.fetch!(reloaded.args, :body) == "SECRETBODY"
        assert JobPayload.fetch!(reloaded.args, :chat_id) == 4_242_424_242

        {:ok, job2} =
          reloaded.args |> Map.put("_attempt", 2) |> TelegramOutboundWorker.new() |> Oban.insert()

        r2 = Repo.get!(Oban.Job, job2.id)
        assert JobPayload.fetch!(r2.args, :body) == "SECRETBODY"
        refute raw_args(job2.id) =~ "SECRETBODY"
      end
    end

    test "message worker: sealed, uniqueness by update_id still dedups" do
      msg = %{
        "text" => "SECRETTEXT",
        "chat" => %{"id" => 777_777_777},
        "from" => %{"first_name" => "Ana"}
      }

      {:ok, j1} =
        %{telegram_update_id: 9001, message: msg} |> TelegramMessageWorker.new() |> Oban.insert()

      {:ok, j2} =
        %{telegram_update_id: 9001, message: msg} |> TelegramMessageWorker.new() |> Oban.insert()

      assert j2.conflict?
      assert j1.id == j2.id
      raw = raw_args(j1.id)
      refute raw =~ "SECRETTEXT"
      refute raw =~ "777777777"
      refute raw =~ "Ana"
    end
  end
end
