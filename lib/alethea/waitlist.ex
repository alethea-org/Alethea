defmodule Alethea.Waitlist do
  @moduledoc """
  Launch waitlist collected from the public landing page.
  """
  alias Alethea.Repo
  alias Alethea.Waitlist.Entry

  @doc "A blank changeset for the landing form."
  def change_entry(attrs \\ %{}), do: Entry.changeset(%Entry{}, attrs)

  @doc """
  Adds someone to the waitlist.

  Signing up again with an email already on the list succeeds without
  changing the stored entry, so the form never reveals who is on it.
  """
  def join(attrs) do
    changeset = change_entry(attrs)

    if changeset.valid? do
      changeset
      |> Repo.insert(on_conflict: :nothing, conflict_target: :email)
      |> case do
        {:ok, _entry} -> :ok
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, %{changeset | action: :insert}}
    end
  end
end
