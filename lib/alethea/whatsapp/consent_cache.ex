defmodule Alethea.WhatsApp.ConsentCache do
  @moduledoc """
  Caché temporal para evitar re-enviar el mensaje de consentimiento legales
  múltiples veces si el paciente envía varios mensajes seguidos.
  """
  use GenServer

  @table :whatsapp_consent_cache
  @ttl :timer.minutes(1)

  # API

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Marca que un número está en proceso de onboarding (se le envió los términos).
  """
  def mark_in_progress(phone) do
    expiration = System.system_time(:second) + div(@ttl, 1000)
    :ets.insert(@table, {phone, expiration})
    :ok
  end

  @doc """
  Verifica si un número ya tiene un onboarding en curso (dentro del TTL).
  """
  def in_progress?(phone) do
    now = System.system_time(:second)

    case :ets.lookup(@table, phone) do
      [{^phone, expiration}] when expiration > now -> true
      _ -> false
    end
  end

  # Callbacks

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    # Tarea de limpieza periódica cada minuto
    :timer.send_interval(@ttl, :cleanup)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)

    # Eliminar registros expirados
    :ets.select_delete(@table, [{{:"$1", :"$2"}, [{:<, :"$2", now}], [true]}])

    {:noreply, state}
  end
end
