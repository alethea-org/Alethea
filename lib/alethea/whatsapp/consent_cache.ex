defmodule Alethea.WhatsApp.ConsentCache do
  @moduledoc """
  Hybrid cache for consent: ETS for fast reads, DB for persistence.
  """
  use GenServer
  import Ecto.Query

  alias Alethea.WhatsApp.ConsentLog

  @table :whatsapp_consent_cache
  @ttl :timer.minutes(30)
  @cache_ttl :timer.minutes(1)

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def mark_in_progress(phone) do
    phone_hash = hash_phone(phone)
    persist_consent_event(phone, phone_hash, "pending", "consent_sent")

    expiration = System.system_time(:second) + div(@cache_ttl, 1000)
    :ets.insert(@table, {phone, :in_progress, expiration})
    :ok
  end

  def mark_accepted(phone) do
    phone_hash = hash_phone(phone)
    persist_consent_event(phone, phone_hash, "accepted", "consent_accepted")

    expiration = System.system_time(:second) + div(@ttl, 1000)
    :ets.insert(@table, {phone, :accepted, expiration})
    :ok
  end

  def mark_rejected(phone) do
    phone_hash = hash_phone(phone)
    persist_consent_event(phone, phone_hash, "rejected", "consent_rejected")

    expiration = System.system_time(:second) + div(@ttl, 1000)
    :ets.insert(@table, {phone, :rejected, expiration})
    :ok
  end

  def in_progress?(phone) do
    now = System.system_time(:second)

    case :ets.lookup(@table, phone) do
      [{^phone, :in_progress, exp}] when exp > now -> true
      _ -> false
    end
  end

  def accepted?(phone) do
    now = System.system_time(:second)

    case :ets.lookup(@table, phone) do
      [{^phone, :accepted, exp}] when exp > now -> true
      _ -> check_db_consent_status(phone) == :accepted
    end
  end

  @impl true
  def init(_) do
    # Protected: solo este GenServer puede escribir, cualquier proceso puede leer
    # Esto previene escritura maliciosa desde otros procesos mientras mantiene
    # la velocidad de lectura sin mensajes al GenServer
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    load_from_db()
    :timer.send_interval(@cache_ttl, :cleanup)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{:"$1", :"$2", :"$3"}, [{:<, :"$3", now}], [true]}])
    {:noreply, state}
  end

  defp hash_phone(phone) do
    :crypto.mac(:hmac, :sha256, Application.fetch_env!(:alethea, :phone_hash_secret), phone)
    |> Base.encode64()
  end

  defp persist_consent_event(phone, phone_hash, status, event_type) do
    try do
      %ConsentLog{}
      |> Ecto.Changeset.change(%{
        whatsapp_number: phone,
        phone_hash: phone_hash,
        status: status,
        event_type: event_type
      })
      |> Alethea.Repo.insert()
    rescue
      _ -> :ok
    end
  end

  defp check_db_consent_status(phone) do
    try do
      result =
        Alethea.Repo.one(
          from(c in ConsentLog,
            where: c.whatsapp_number == ^phone,
            order_by: [desc: c.inserted_at],
            limit: 1
          )
        )

      case result do
        nil -> :unknown
        %{status: "accepted"} -> :accepted
        %{status: "rejected"} -> :rejected
        _ -> :pending
      end
    rescue
      _ -> :unknown
    end
  end

  defp load_from_db do
    try do
      since = DateTime.add(DateTime.utc_now(), -24, :hour)

      logs =
        Alethea.Repo.all(
          from(c in ConsentLog,
            where: c.inserted_at > ^since,
            where: c.status in ["accepted", "rejected"],
            order_by: [desc: c.inserted_at],
            select: {c.whatsapp_number, c.status}
          )
        )
        |> Enum.uniq_by(fn {p, _} -> p end)

      exp = System.system_time(:second) + div(@ttl, 1000)
      entries = Enum.map(logs, fn {p, s} -> {p, String.to_existing_atom(s), exp} end)
      :ets.insert(@table, entries)
    rescue
      _ -> :ok
    end
  end
end
