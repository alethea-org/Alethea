defmodule AletheaWeb.GroundedChat.FollowupState do
  @moduledoc """
  Estado efímero acotado para los seguimientos del chat de consulta
  clínica fundamentada (ADR-010 §6 — `openspec/adr/010`).

  ## Invariantes (romperlas = bug que rompe ADR-010)

    1. **Exclusivo del proceso LiveView.** Vive únicamente en
       `socket.assigns.followup_state`. Si sus campos aparecen fuera
       de ese socket (DB, ETS, browser, auditoría, metadatos de
       acceso) es un bug. Verificado por
       `AletheaWeb.GroundedChat.FollowupStateNoPersistenceTest`.

    2. **Acotado.** Ring buffer con `max_turns = 6`. No crece sin
       límite aunque el psicólogo encadene muchos turnos.

    3. **No es evidencia.** Cada turno guarda sólo `query` (resumido)
       y `refs` (`MapSet` de `source_ref` server-derived). Nunca
       guarda el texto de la respuesta, ni excerpts de citas, ni
       síntesis. El tipo del campo hace imposible, en compilación,
       que se inyecte como evidencia al retrieve.

    4. **Sólo desambigua.** `refs_for/2` retorna
       `MapSet.t(source_ref)` para que el contrato de consulta (B2,
       issue #233) sepa qué fuentes ya mostramos; nada más. El
       retrieve nunca recibe este estado como evidencia — sólo como
       pista de qué referencias evitar duplicar en el panel.

    5. **Reset obligatorio en:** mount con cambio de paciente,
       nueva conversación, navegación fuera de la ruta, remount del
       LiveView y logout (logout mata el proceso → GC automático de
       todas las asignaciones de socket).

  ## Hand-off

    * A2 (issue #227) crea `AletheaWeb.ConsultationLive` y la asigna
      en su `mount/3`: `assign(socket, :followup_state, FollowupState.new(patient_id))`.
    * B2 (issue #233) recibe el `t()` y consume sólo `refs_for/2` y
      `last_index/1` para desambiguar; nunca su contenido como
      evidencia en el retrieve.
    * B3 (issue #236) añade el handler `phx-click="new_conversation"`
      que invoca `reset/0`.
  """

  defmodule Turn do
    @moduledoc """
    Una entrada del ring buffer. Sólo datos para desambiguar.

    Su forma es la enforcement mecánica del invariante #3: el campo
    `refs/0` no puede contener excerpts porque su tipo es
    `MapSet.t(source_ref)` y el struct no expone nada más.
    """

    @type source_ref :: String.t()
    @type query_summary :: String.t()

    @max_query_length 240

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            query: query_summary(),
            refs: MapSet.t(source_ref()),
            inserted_at: DateTime.t()
          }

    @enforce_keys [:index, :query, :refs, :inserted_at]
    defstruct [:index, :query, :refs, :inserted_at]

    @spec build(non_neg_integer(), query_summary(), [source_ref()]) :: t()
    def build(index, query, refs)
        when is_integer(index) and index >= 0 and is_binary(query) and is_list(refs) do
      trimmed =
        query
        |> String.trim()
        |> String.slice(0, @max_query_length)

      %__MODULE__{
        index: index,
        query: trimmed,
        refs: MapSet.new(refs, &normalize_ref/1),
        inserted_at: DateTime.utc_now()
      }
    end

    defp normalize_ref(ref) when is_binary(ref), do: ref
    defp normalize_ref(other), do: to_string(other)
  end

  @default_max_turns 6

  @type t :: %__MODULE__{
          patient_id: String.t() | nil,
          turns: %{non_neg_integer() => Turn.t()},
          max_turns: pos_integer()
        }

  defstruct patient_id: nil, turns: %{}, max_turns: @default_max_turns

  @doc """
  Estado inicial ligado al `patient_id` autorizado.

  Usar en `mount/3` de la LiveView **después** de verificar que el
  paciente pertenece al tenant del psicólogo (cross-tenant guard de
  A2 / issue #227). Si el `patient_id` cambia durante la misma
  sesión, invocar primero `reset/0` para no transferir turnos entre
  pacientes (invariante #5).
  """
  @spec new(String.t()) :: t()
  def new(patient_id) when is_binary(patient_id) do
    %__MODULE__{patient_id: patient_id}
  end

  @doc """
  Estado totalmente vacío.

  Disparar en: logout (la LiveView muere y el GC se encarga, pero
  llamarlo explícitamente no hace daño), `handle_event
  "new_conversation"`, navegación fuera de la ruta hacia otra
  LiveView, y remount del proceso.
  """
  @spec reset() :: t()
  def reset, do: %__MODULE__{}

  @doc """
  Backward-compatible variant to support pipelined callers.
  """
  @spec reset(any()) :: t()
  def reset(_state), do: reset()

  @doc """
  ¿Hay una conversación en curso?

  `false` ≡ slot recién reseteado o todavía no inicializado para el
  paciente actual.
  """
  @spec current?(t()) :: boolean()
  def current?(%__MODULE__{turns: turns}), do: map_size(turns) > 0

  @doc """
  Índice del turno más reciente, o `nil` si no hay ninguno.

  B2 (issue #233) lo usa para etiquetar el retrieve con
  `"turno N → turno N+1"` y así reconstruir la intención del
  seguimiento sin tratar el contenido previo como evidencia.
  """
  @spec last_index(t()) :: non_neg_integer() | nil
  def last_index(%__MODULE__{turns: turns}) do
    case map_size(turns) do
      0 -> nil
      _ -> turns |> Map.keys() |> Enum.max()
    end
  end

  @doc """
  Conjunto de `source_ref` server-derived del turno `index`.
  Retorna `MapSet.new()` si el turno no existe.

  **Nunca contiene excerpts**: por tipo (`MapSet.t(source_ref)`) es
  imposible usarlo como evidencia en el retrieve. Lo consume B2 sólo
  para deduplicar el panel de fuentes mostrado al psicólogo.
  """
  @spec refs_for(t(), non_neg_integer()) :: MapSet.t(String.t())
  def refs_for(%__MODULE__{turns: turns}, index) when is_integer(index) do
    case Map.get(turns, index) do
      nil -> MapSet.new()
      %Turn{refs: refs} -> refs
    end
  end

  @doc """
  Registra un turno nuevo. Si el total supera `max_turns` (= 6), el
  más viejo se descarta (ring buffer FIFO por `index`).

  El `index` debe ser monotónicamente creciente dentro de la sesión:
  el contrato de B2 es responsable de mantener esa monotonía.
  """
  @spec record_turn(t(), non_neg_integer(), String.t(), [String.t()]) :: t()
  def record_turn(%__MODULE__{turns: turns, max_turns: max} = state, index, query, refs)
      when is_integer(index) and index >= 0 and is_binary(query) and is_list(refs) do
    new_turn = Turn.build(index, query, refs)
    merged = Map.put(turns, index, new_turn)
    %__MODULE__{state | turns: prune_to_size(merged, max)}
  end

  defp prune_to_size(turns, max) when map_size(turns) <= max, do: turns

  defp prune_to_size(turns, max) do
    keep_indexes =
      turns
      |> Map.keys()
      |> Enum.sort()
      |> Enum.take(-max)

    Map.take(turns, keep_indexes)
  end
end
