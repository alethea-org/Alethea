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
    |> redact_phone()
    |> redact_document_id()
    |> String.trim()
  end

  defp redact_email(text) do
    Regex.replace(~r/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i, text, "[REDACTED_EMAIL]")
  end

  defp redact_phone(text) do
    # Match various phone formats:
    # - International with country code: +56 9 1234 5678, +1 (555) 123-4567
    # - Formatted local: 9 1234 5678, (555) 123-4567
    # - Chilean mobile: 9 digits starting with 9 (with spaces)
    # - Plain Chilean local: 9XXXXXXXX (9 digit mobile)
    # - Chilean landline: 2XXXXXXXX (9 digit local)
    Regex.replace(
      ~r/\+[0-9]{1,3}[ .\-]?[0-9][0-9 .\-()]{6,}|\(?[0-9]{2,4}\)?[ .\-][0-9][0-9 .\-]{5,}[0-9]| [0-9][0-9][ .\-][0-9]{3,4}[ .\-][0-9]{3,4}(?![0-9])|\b[29][0-9]{8}\b/,
      text,
      "[REDACTED_PHONE]"
    )
  end

  defp redact_ssn(text) do
    Regex.replace(~r/\b\d{3}-\d{2}-\d{4}\b/, text, "[REDACTED_SSN]")
  end

  defp redact_document_id(text) do
    # Match exactly 9 digits (common in Latin America for RUT, DNI, etc.)
    # Not followed by another digit (to avoid matching 10-digit phone numbers)
    Regex.replace(~r/\b\d{9}\b(?![0-9])/, text, "[REDACTED_ID]")
  end
end
