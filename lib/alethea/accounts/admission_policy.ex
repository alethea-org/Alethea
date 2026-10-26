defmodule Alethea.Accounts.AdmissionPolicy do
  @moduledoc """
  Controls access admission for the hosted synthetic-data demonstration profile.

  When `demo_restricted_access` is enabled (production only, via `DEMO_RESTRICTED_ACCESS=true`),
  only emails explicitly enumerated in `demo_allowed_emails` (from `DEMO_ALLOWED_EMAILS`)
  are admitted. When restricted access is off, open registration and login operate normally.
  """

  @doc """
  Returns true only when the demonstration access restriction is explicitly enabled.
  """
  @spec restricted?() :: boolean()
  def restricted? do
    Application.get_env(:alethea, :demo_restricted_access) == true
  end

  @doc """
  Checks whether the given email address is permitted under the current admission policy.

  - When unrestricted, always returns `true`.
  - When restricted, performs case-normalized membership check against the configured allowlist.
  - When restricted and the allowlist is empty or missing, fails closed and returns `false`.
  """
  @spec allowed_email?(String.t() | nil) :: boolean()
  def allowed_email?(email) do
    if restricted?() do
      case email do
        binary when is_binary(binary) ->
          normalized = binary |> String.trim() |> String.downcase()
          normalized != "" and normalized in allowed_emails()

        _other ->
          false
      end
    else
      true
    end
  end

  defp allowed_emails do
    case Application.get_env(:alethea, :demo_allowed_emails) do
      emails when is_list(emails) ->
        emails
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
        |> Enum.reject(&(&1 == ""))

      _other ->
        []
    end
  end
end
