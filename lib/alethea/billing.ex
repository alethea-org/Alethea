defmodule Alethea.Billing do
  @moduledoc """
  Paid access for professionals through Paddle Billing (Merchant of Record).

  The rest of the app asks one question, `entitled?/1`. Subscription state
  changes only through `apply_event/1`, fed by verified Paddle webhooks;
  the browser checkout result never grants access.

  Billing is disabled (everyone entitled) when Paddle is not configured or
  the synthetic demo profile is active, so demos and development keep
  working without Paddle.

  Only the professional's email and Alethea id ever go to Paddle.
  """

  import Ecto.Query

  alias Alethea.Accounts
  alias Alethea.Accounts.Professional
  alias Alethea.Billing.{Event, ProcessedEvent, Subscription}
  alias Alethea.Repo

  require Logger

  @entitled_statuses ~w(trialing active past_due)

  # ── Configuration ────────────────────────────────────────────────

  @doc "Whether paid access is enforced."
  @spec enabled?() :: boolean()
  def enabled?, do: config(:enabled, false) == true

  @doc "Paddle webhook secret key used to verify `Paddle-Signature`."
  def webhook_secret, do: config(:webhook_secret)

  defp config(key, default \\ nil) do
    :alethea
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  # ── Entitlement ──────────────────────────────────────────────────

  @doc """
  Whether `professional` may use the clinical workspace.

  Entitled when the subscription is `trialing`, `active` or `past_due`
  (Paddle keeps `past_due` only while it retries the payment, then
  cancels), or `canceled` with the paid period still running, and only
  for a price listed in `PADDLE_PRICE_IDS`. Always entitled while billing
  is disabled.
  """
  @spec entitled?(Professional.t() | %{id: binary()}) :: boolean()
  def entitled?(%{id: professional_id}) do
    if enabled?() do
      professional_id
      |> subscription_for()
      |> subscription_entitled?(DateTime.utc_now())
    else
      true
    end
  end

  defp subscription_entitled?(nil, _now), do: false

  # The price is picked client-side in Paddle.js, so a subscription to any
  # other price the vendor account sells (a test, trial or cheaper plan)
  # must not unlock the workspace.
  defp subscription_entitled?(%Subscription{price_id: price_id} = subscription, now) do
    price_id in config(:price_ids, []) and paid_period?(subscription, now)
  end

  defp paid_period?(%Subscription{status: status}, _now)
       when status in @entitled_statuses,
       do: true

  defp paid_period?(
         %Subscription{status: "canceled", current_period_ends_at: %DateTime{} = ends_at},
         now
       ),
       do: DateTime.compare(ends_at, now) == :gt

  defp paid_period?(_subscription, _now), do: false

  @doc "The professional's subscription record, or `nil`."
  @spec current_subscription(Professional.t() | %{id: binary()}) :: Subscription.t() | nil
  def current_subscription(%{id: professional_id}), do: subscription_for(professional_id)

  defp subscription_for(professional_id),
    do: Repo.get_by(Subscription, professional_id: professional_id)

  # ── Webhook events ───────────────────────────────────────────────

  @doc """
  Applies one verified, normalized Paddle event.

  Idempotent on the Paddle `event_id` and order-safe on `occurred_at`:
  an event older than the last one applied to the subscription is
  recorded but does not change state. Returns `{:ok, outcome}` where
  outcome is `:applied`, `:duplicate`, `:stale`, `:superseded` or `:unlinked`.
  """
  @spec apply_event(Event.t()) ::
          {:ok, :applied | :duplicate | :stale | :superseded | :unlinked} | {:error, term()}
  def apply_event(%Event{} = event) do
    Repo.transaction(fn ->
      with :new <- claim_event(event),
           {:ok, subscription} <- locate(event),
           :fresh <- freshness(subscription, event),
           {:ok, saved} <- persist(subscription, event) do
        audit(saved, subscription, event)
        mark_outcome(event, "applied")
        {:applied, saved}
      else
        :duplicate ->
          :duplicate

        :unlinked ->
          mark_outcome(event, "unlinked")
          :unlinked

        :stale ->
          mark_outcome(event, "stale")
          :stale

        :superseded ->
          mark_outcome(event, "superseded")
          :superseded

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {:applied, saved}} ->
        broadcast(saved.professional_id)
        {:ok, :applied}

      {:ok, :unlinked} ->
        Logger.warning("Paddle event could not be linked to a professional",
          paddle_event_id: event.id,
          paddle_event_type: event.type
        )

        {:ok, :unlinked}

      other ->
        other
    end
  end

  # Inserting the processed-event row first makes concurrent deliveries of
  # the same event serialize on the primary key: the loser sees a conflict.
  defp claim_event(event) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Repo.insert_all(
        ProcessedEvent,
        [%{event_id: event.id, event_type: event.type, outcome: "pending", inserted_at: now}],
        on_conflict: :nothing,
        conflict_target: :event_id
      )

    if count == 1, do: :new, else: :duplicate
  end

  defp mark_outcome(event, outcome) do
    from(p in ProcessedEvent, where: p.event_id == ^event.id)
    |> Repo.update_all(set: [outcome: outcome])
  end

  defp locate(%Event{} = event) do
    by_subscription =
      from(s in Subscription,
        where: s.paddle_subscription_id == ^event.paddle_subscription_id,
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    cond do
      by_subscription ->
        {:ok, by_subscription}

      linkable?(event) ->
        from(s in Subscription,
          where: s.professional_id == ^event.professional_id,
          lock: "FOR UPDATE"
        )
        |> Repo.one()
        |> link(event)

      true ->
        :unlinked
    end
  end

  # An event for a Paddle subscription Alethea has not stored yet. It may
  # create the professional's row, or replace the stored subscription, only
  # when it starts a new paid subscription. A late event from an older,
  # abandoned subscription (or a status-less transaction) never takes over
  # the row.
  defp link(nil, %Event{status: nil}), do: :unlinked

  defp link(nil, %Event{} = event),
    do: {:ok, %Subscription{professional_id: event.professional_id}}

  defp link(%Subscription{} = existing, %Event{status: status})
       when status in ["active", "trialing"],
       do: {:ok, existing}

  defp link(%Subscription{}, %Event{}), do: :superseded

  # `custom_data` is set client-side in Paddle.js, so the professional id in
  # it is trusted only with the server-issued link token from
  # `checkout_config/1`. Without it, anyone could pay and relink another
  # professional's subscription.
  defp linkable?(%Event{professional_id: id, link_token: token})
       when is_binary(id) and is_binary(token) do
    Plug.Crypto.secure_compare(token, link_token(id)) and Repo.get(Professional, id) != nil
  end

  defp linkable?(_event), do: false

  @doc """
  HMAC that binds a checkout's `custom_data.professional_id` to this
  server. Keyed with the Paddle webhook secret.
  """
  @spec link_token(binary()) :: String.t()
  def link_token(professional_id) do
    :crypto.mac(
      :hmac,
      :sha256,
      webhook_secret() || "",
      "alethea-billing-link:" <> professional_id
    )
    |> Base.url_encode64(padding: false)
  end

  # Status-less events (`transaction.completed`) only link ids, so they
  # neither take part in nor move the ordering watermark.
  defp freshness(_subscription, %Event{status: nil}), do: :fresh
  defp freshness(%Subscription{last_event_occurred_at: nil}, _event), do: :fresh

  defp freshness(%Subscription{last_event_occurred_at: last}, %Event{occurred_at: occurred_at}) do
    if DateTime.compare(occurred_at, last) == :lt, do: :stale, else: :fresh
  end

  defp persist(%Subscription{} = subscription, %Event{} = event) do
    attrs =
      %{
        paddle_subscription_id: event.paddle_subscription_id,
        paddle_customer_id: event.paddle_customer_id || subscription.paddle_customer_id,
        price_id: event.price_id || subscription.price_id,
        last_event_occurred_at: watermark(subscription, event)
      }
      |> Map.merge(status_attrs(subscription, event))

    subscription
    |> Subscription.changeset(attrs)
    |> Repo.insert_or_update()
  end

  defp watermark(%Subscription{last_event_occurred_at: %DateTime{} = last}, %Event{status: nil}),
    do: last

  defp watermark(_subscription, %Event{occurred_at: occurred_at}), do: occurred_at

  # `transaction.completed` carries no status: it only links ids on an
  # existing row (it never creates one, see `link/2`).
  defp status_attrs(subscription, %Event{status: nil}), do: %{status: subscription.status}

  defp status_attrs(subscription, %Event{} = event) do
    %{
      status: event.status,
      current_period_ends_at: event.current_period_ends_at || subscription.current_period_ends_at,
      cancel_at_period_end: event.cancel_at_period_end
    }
  end

  defp audit(saved, previous, event) do
    {:ok, _log} =
      Accounts.log_action(%{
        action: "BILLING_SUBSCRIPTION_CHANGED",
        professional_id: saved.professional_id,
        resource_type: "billing_subscription",
        resource_id: saved.id,
        details: %{
          paddle_event_id: event.id,
          paddle_event_type: event.type,
          from_status: previous.status,
          to_status: saved.status,
          current_period_ends_at: saved.current_period_ends_at,
          cancel_at_period_end: saved.cancel_at_period_end
        }
      })
  end

  # ── Live updates ─────────────────────────────────────────────────

  @doc "PubSub topic notified whenever the professional's subscription changes."
  def topic(professional_id), do: "billing:#{professional_id}"

  @doc "Subscribes the caller to the professional's subscription changes."
  def subscribe(professional_id),
    do: Phoenix.PubSub.subscribe(Alethea.PubSub, topic(professional_id))

  defp broadcast(professional_id) do
    Phoenix.PubSub.broadcast(
      Alethea.PubSub,
      topic(professional_id),
      {:billing_updated, professional_id}
    )
  end

  # ── Checkout and customer portal ─────────────────────────────────

  @doc """
  Client-side configuration for Paddle.js overlay checkout. Carries only
  the professional's email and Alethea id (plus the link token that
  authenticates that id when it comes back in a webhook).
  """
  @spec checkout_config(Professional.t()) :: map()
  def checkout_config(%Professional{} = professional) do
    %{
      client_token: config(:client_token),
      environment: environment(),
      price_ids: config(:price_ids, []),
      email: professional.email,
      custom_data: %{professional_id: professional.id, link_token: link_token(professional.id)}
    }
  end

  @doc """
  Creates an authenticated Paddle customer portal session for the
  professional and returns its URL.
  """
  @spec customer_portal_url(Professional.t()) :: {:ok, String.t()} | {:error, term()}
  def customer_portal_url(%Professional{} = professional) do
    case current_subscription(professional) do
      %Subscription{paddle_customer_id: customer_id} = subscription when is_binary(customer_id) ->
        request_portal_session(customer_id, subscription.paddle_subscription_id)

      _ ->
        {:error, :no_customer}
    end
  end

  defp request_portal_session(customer_id, subscription_id) do
    url = "#{api_base_url()}/customers/#{URI.encode(customer_id)}/portal-sessions"

    options =
      [json: %{subscription_ids: List.wrap(subscription_id)}, auth: {:bearer, config(:api_key)}] ++
        config(:req_options, [])

    case Req.post(url, options) do
      {:ok,
       %Req.Response{
         status: status,
         body: %{"data" => %{"urls" => %{"general" => %{"overview" => overview}}}}
       }}
      when status in 200..299 and is_binary(overview) ->
        {:ok, overview}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp environment do
    case config(:environment, "sandbox") do
      "production" -> "production"
      _ -> "sandbox"
    end
  end

  defp api_base_url do
    case environment() do
      "production" -> "https://api.paddle.com"
      "sandbox" -> "https://sandbox-api.paddle.com"
    end
  end
end
