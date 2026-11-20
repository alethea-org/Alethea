defmodule Alethea.Billing.Event do
  @moduledoc """
  A verified Paddle webhook notification, normalized to the fields
  `Alethea.Billing.apply_event/1` needs.

  Subscription events (`subscription.*`) carry the full subscription
  entity. `transaction.completed` carries a transaction: it links the
  Paddle customer and subscription ids but never changes the status
  (`status` is `nil`), because Paddle follows it with a subscription
  event that does.
  """

  alias Alethea.Billing.Subscription

  @subscription_events ~w(
    subscription.created
    subscription.activated
    subscription.updated
    subscription.trialing
    subscription.past_due
    subscription.paused
    subscription.resumed
    subscription.canceled
  )

  @enforce_keys [:id, :type, :occurred_at]
  defstruct [
    :id,
    :type,
    :occurred_at,
    :paddle_subscription_id,
    :paddle_customer_id,
    :professional_id,
    :link_token,
    :status,
    :price_id,
    :current_period_ends_at,
    cancel_at_period_end: false
  ]

  @type t :: %__MODULE__{}

  @doc "Event types this module normalizes."
  def handled_types, do: ["transaction.completed" | @subscription_events]

  @doc """
  Normalizes a decoded Paddle notification payload.

  Returns `{:ok, event}`, `{:ignore, type}` for event types Alethea does
  not act on, or `{:error, :malformed}`.
  """
  @spec from_payload(map()) :: {:ok, t()} | {:ignore, String.t()} | {:error, :malformed}
  def from_payload(
        %{
          "event_id" => id,
          "event_type" => type,
          "occurred_at" => occurred_at,
          "data" => %{} = data
        } = _payload
      )
      when is_binary(id) and is_binary(type) and is_binary(occurred_at) do
    with {:ok, occurred_at, _offset} <- DateTime.from_iso8601(occurred_at),
         {:ok, fields} <- data_fields(type, data) do
      {:ok,
       struct!(__MODULE__, Map.merge(fields, %{id: id, type: type, occurred_at: occurred_at}))}
    else
      {:ignore, _} = ignore -> ignore
      _ -> {:error, :malformed}
    end
  end

  def from_payload(_payload), do: {:error, :malformed}

  defp data_fields(type, data) when type in @subscription_events do
    with %{"id" => sub_id, "status" => status} when is_binary(sub_id) <- data,
         true <- status in Subscription.statuses(),
         {:ok, period_end} <-
           optional_datetime(get_in(data, ["current_billing_period", "ends_at"])) do
      {:ok,
       %{
         paddle_subscription_id: sub_id,
         paddle_customer_id: string_or_nil(data["customer_id"]),
         professional_id: professional_id(data["custom_data"]),
         link_token: link_token(data["custom_data"]),
         status: status,
         price_id: first_price_id(data["items"]),
         current_period_ends_at: period_end,
         cancel_at_period_end: get_in(data, ["scheduled_change", "action"]) == "cancel"
       }}
    else
      _ -> :error
    end
  end

  defp data_fields("transaction.completed", data) do
    case data do
      %{"subscription_id" => sub_id} when is_binary(sub_id) ->
        {:ok,
         %{
           paddle_subscription_id: sub_id,
           paddle_customer_id: string_or_nil(data["customer_id"]),
           professional_id: professional_id(data["custom_data"]),
           link_token: link_token(data["custom_data"]),
           price_id: first_price_id(data["items"])
         }}

      # One-off transactions without a subscription do not affect access.
      _ ->
        {:ignore, "transaction.completed"}
    end
  end

  defp data_fields(type, _data), do: {:ignore, type}

  defp optional_datetime(nil), do: {:ok, nil}

  defp optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, DateTime.truncate(dt, :second)}
      _ -> :error
    end
  end

  defp optional_datetime(_), do: :error

  defp professional_id(%{"professional_id" => id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp professional_id(_), do: nil

  defp link_token(%{"link_token" => token}) when is_binary(token), do: token
  defp link_token(_), do: nil

  defp first_price_id([%{"price" => %{"id" => id}} | _]) when is_binary(id), do: id
  defp first_price_id([%{"price_id" => id} | _]) when is_binary(id), do: id
  defp first_price_id(_), do: nil

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_), do: nil
end
