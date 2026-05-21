defmodule Alethea.AI.Sanitizer do
  @moduledoc """
  Filtra contenido sensible antes de enviarlo a cualquier chain de LangChain.

  Este módulo es un punto central para proteger la privacidad del paciente.
  """

  @spec sanitize(String.t() | nil) :: String.t()
  def sanitize(nil), do: ""

  def sanitize(content) when is_binary(content) do
    content
    |> redact_email()
    |> redact_ssn()
    |> redact_document_id()
    |> redact_phone()
    |> String.trim()
  end

  defp redact_email(text) do
    Regex.replace(~r/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i, text, "[REDACTED_EMAIL]")
  end

  defp redact_phone(text) do
    Regex.replace(~r/\+?[0-9][0-9 \-\.]{7,}[0-9]/, text, "[REDACTED_PHONE]")
  end

  defp redact_ssn(text) do
    Regex.replace(~r/\b\d{3}-\d{2}-\d{4}\b/, text, "[REDACTED_SSN]")
  end

  defp redact_document_id(text) do
    Regex.replace(~r/\b\d{9}\b/, text, "[REDACTED_ID]")
  end
end
