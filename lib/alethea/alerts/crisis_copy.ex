defmodule Alethea.Alerts.CrisisCopy do
  @moduledoc """
  Single source for the patient-facing crisis-bypass reply text.

  The psychologist preconfigures a per-professional `crisis_message`. If it
  is unset (`nil`), the text falls back to the `:crisis_support_message`
  application env, and finally to a system default. An empty-string
  `crisis_message` is passed through unchanged.
  """

  @doc """
  Resolves the crisis reply text for a patient whose `:professional` is
  loaded.
  """
  def reply_text(legacy_patient) do
    legacy_patient.professional.crisis_message ||
      Application.get_env(
        :alethea,
        :crisis_support_message,
        default_support_message()
      )
  end

  @doc """
  System default crisis support message.
  """
  def default_support_message do
    "Entiendo que estás pasando por algo muy difícil. Lo que sientes importa."
  end
end
