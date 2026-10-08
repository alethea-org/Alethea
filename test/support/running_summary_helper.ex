defmodule Alethea.RunningSummaryHelper do
  @moduledoc false
  # Seeds journaling turns for the running-summary (#394) worker/schedule tests.
  import Ecto.Query

  alias Alethea.{Clinical, Repo}
  alias Alethea.Clinical.Message
  alias Alethea.Clinical.RunningSummary
  alias Alethea.Encryption.PatientVault

  @base ~U[2026-01-01 00:00:00Z]

  @doc """
  Saves inbound turns `range` (content `"paciente N"`), each followed one
  second later by an outbound `"alethea N"` reply. Returns the inbounds.
  """
  def seed(patient, dek, range, opts \\ []) do
    behavior = Keyword.get(opts, :inbound_behavior, "spontaneous")

    Enum.map(range, fn i ->
      inbound = turn(patient, dek, "inbound", behavior, "paciente #{i}", 2 * i)
      turn(patient, dek, "outbound", "elicited", "alethea #{i}", 2 * i + 1)
      inbound
    end)
  end

  def turn(patient, dek, direction, behavior, text, offset) do
    {:ok, message} = Clinical.save_message(patient, text, dek, direction, behavior)

    Repo.update_all(from(m in Message, where: m.id == ^message.id),
      set: [timestamp: DateTime.add(@base, offset, :second)]
    )

    Repo.get!(Message, message.id)
  end

  @doc "Writes a stored row directly (ciphertext sealed under `dek`)."
  def put_row(patient, dek, text, mode, expected, count, target) do
    {:ok, ciphertext} = PatientVault.encrypt(text, dek)
    plan = %{mode: mode, expected: expected, target_count: count, target: target}
    :ok = RunningSummary.write(plan, ciphertext, patient)
  end

  @valid "Hechos que la persona relató:\n- Salió a caminar con su hermana\n\n" <>
           "Preguntas que Alethea hizo:\n- ¿Cómo dormiste?"

  def valid_summary, do: @valid
end
