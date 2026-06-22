defmodule Alethea.Repo.Migrations.AddCrisisBypassToMessageBehaviorType do
  @moduledoc """
  Widens the `messages.behavior_type` check constraint to include
  `crisis_bypass` alongside the existing `spontaneous` and `elicited`
  values.

  Per `REQ-C5-persist-outbound-reply` "crisis reply is persisted
  with crisis_bypass source", the crisis branch of the Telegram
  clinical round-trip must persist outbound messages with
  `behavior_type = "crisis_bypass"`. The PR #3a migration
  `20260526125520_add_behavior_type_to_messages.exs` constrained
  the column to `("spontaneous", "elicited")` only — a WhatsApp-era
  enum that did not anticipate the crisis-bypass value.

  ## Why a separate migration (not folded into PR #3a)

  PR #3a was scoped to the safe path. Widening the enum there
  would have left a half-state where the schema accepts a value
  no worker writes. PR #3b is the first slice that actually
  persists the `crisis_bypass` value, so the migration lands
  here.

  ## Backward compatibility

  All pre-existing rows have `behavior_type IN ("spontaneous", "elicited")`
  (the previous constraint). The new constraint is a strict
  superset — no migration of existing data is required.

  ## Out of scope

  The `Alethea.Clinical.Message.changeset/2` validation list and
  Ecto cast list are updated in the same PR to keep the schema,
  validation, and DB constraint in lockstep.
  """

  use Ecto.Migration

  def change do
    drop_if_exists constraint(:messages, :behavior_type_must_be_valid)

    create constraint(:messages, :behavior_type_must_be_valid,
             check: "behavior_type IN ('spontaneous', 'elicited', 'crisis_bypass')"
           )
  end
end
