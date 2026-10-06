defmodule Alethea.Repo.Migrations.SurfaceAmbiguousTelegramDeliveries do
  @moduledoc """
  Supports surfacing ambiguous Telegram deliveries (issue #390, T4).

    * `foundation_outbound_dead_letters.outcome` — `failed` (the delivery
      is known not to have arrived; every row written so far) or
      `ambiguous` (the request may have reached Telegram; the reply was
      not resent). `last_error` alone cannot tell them apart: a 5xx is a
      retried failure on the crisis lane and an ambiguous outcome on the
      journaling lane.
    * A partial index on `messages (updated_at)` for rows in `sending`,
      so the periodic sweep that resolves expired delivery claims reads a
      handful of index entries instead of scanning `messages`.
  """

  use Ecto.Migration

  def change do
    alter table(:foundation_outbound_dead_letters) do
      add :outcome, :string, null: false, default: "failed"
    end

    create constraint(
             :foundation_outbound_dead_letters,
             :foundation_outbound_dead_letters_outcome_check,
             check: "outcome IN ('failed', 'ambiguous')"
           )

    create index(:messages, [:updated_at],
             where: "delivery_state = 'sending'",
             name: :messages_sending_delivery_claims_index
           )
  end
end
