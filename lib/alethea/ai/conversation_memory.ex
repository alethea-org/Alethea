defmodule Alethea.AI.ConversationMemory do
  @moduledoc """
  Memoria de conversación por sesión para enrichment de prompts.

  Almacena mensajes recientes de cada sesión para dar contexto al LLM.
  Usa ETS para caché rápido in-memory.
  """

  use GenServer

  alias LangChain.Message

  @table :conversation_memory
  @max_messages_per_session 10

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Agrega un mensaje al historial de la sesión.
  """
  @spec add_message(session_id :: String.t(), role :: atom(), content :: String.t()) :: :ok
  def add_message(session_id, role, content) when is_atom(role) and is_binary(content) do
    GenServer.cast(__MODULE__, {:add, session_id, role, content})
  end

  @doc """
  Obtiene los últimos N mensajes de la sesión.
  """
  @spec get_messages(session_id :: String.t(), limit :: pos_integer()) :: [Message.t()]
  def get_messages(session_id, limit \\ @max_messages_per_session) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, messages}] ->
        Enum.take(messages, limit)

      [] ->
        []
    end
  end

  @doc """
  Construye el contexto de mensajes para el LLM.
  """
  @spec build_context(session_id :: String.t()) :: String.t()
  def build_context(session_id) do
    messages = get_messages(session_id)

    if Enum.empty?(messages) do
      ""
    else
      messages
      |> Enum.map(fn msg ->
        role = Map.get(msg, :role, "user")
        content = Map.get(msg, :content, "")
        "[#{role}]: #{content}"
      end)
      |> Enum.join("\n")
    end
  end

  @doc """
  Limpia el historial de una sesión.
  """
  @spec clear_session(session_id :: String.t()) :: :ok
  def clear_session(session_id) do
    GenServer.cast(__MODULE__, {:clear, session_id})
  end

  @impl true
  def init(_) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:add, session_id, role, content}, state) do
    messages =
      case :ets.lookup(@table, session_id) do
        [{^session_id, msgs}] -> msgs
        [] -> []
      end

    new_msg = %Message{role: role, content: content}
    updated = [new_msg | messages] |> Enum.take(@max_messages_per_session)

    :ets.insert(@table, {session_id, updated})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:clear, session_id}, state) do
    :ets.delete(@table, session_id)
    {:noreply, state}
  end
end
