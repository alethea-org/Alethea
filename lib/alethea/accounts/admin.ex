defmodule Alethea.Accounts.Admin do
  @moduledoc """
  Who may open the operator pages under `/admin`.

  An admin is a registered professional whose email is listed in
  `config :alethea, :admin_emails` (from `ADMIN_EMAILS`). The list is
  empty by default, so nobody is an admin until an operator says so.
  Both sides are compared in canonical form
  (`Alethea.Accounts.Professional.normalize_email/1`).
  """

  alias Alethea.Accounts.Professional

  @spec admin?(map() | nil) :: boolean()
  def admin?(%{email: email}) when is_binary(email) do
    normalized = Professional.normalize_email(email)

    Application.get_env(:alethea, :admin_emails, [])
    |> Enum.map(&Professional.normalize_email/1)
    |> Enum.member?(normalized)
  end

  def admin?(_professional), do: false
end
