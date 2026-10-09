defmodule Alethea.Repo.Migrations.AddExplorationStateToMessages do
  @moduledoc """
  Adds the exploration stretch state to outbound Telegram replies
  (issue #393).

    * `exploration_questions` — how many questions have been asked
      about the patient's current situation so far this stretch
      (0-3, DB-checked). `NULL` for untracked rows and for rows
      written before this migration (read as fresh by
      `Alethea.Clinical.exploration_state/3`).
    * `closing_invitation_sent` — whether the soft closing invitation
      has already been sent for this stretch, so a later reply in the
      same stretch becomes a brief acknowledgement instead of
      repeating the invitation.

  Both columns are non-sensitive, non-PHI metadata — counters and a
  flag only, never the situation's text, which stays in the existing
  encrypted column.
  """

  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :exploration_questions, :smallint
      add :closing_invitation_sent, :boolean
    end

    create constraint(:messages, :messages_exploration_questions_check,
             check: "exploration_questions IS NULL OR exploration_questions BETWEEN 0 AND 3"
           )
  end
end
