defmodule Alethea.Foundation.Migrations.RedactOutboundDeadLetterTextTest do
  @moduledoc """
  S2 (security-audit-run-2): `RedactOutboundDeadLetterText` clears the
  reply bodies that dead-letter rows used to store in clear.

  The test database is migrated once at suite boot, so the migration's
  data function runs here against rows inserted in the sandbox with a
  body, as rows written before the migration have (migration files are
  not compiled by `mix test`, so the file is required here).
  """

  use Alethea.DataCase, async: true

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20261127132455_redact_outbound_dead_letter_text.exs",
                    __DIR__
                  )

  setup_all do
    Code.require_file(@migration_path)
    :ok
  end

  alias Alethea.Repo.Migrations.RedactOutboundDeadLetterText, as: Migration

  defp insert_legacy_row!(text) do
    Repo.query!(
      """
      INSERT INTO foundation_outbound_dead_letters
        (id, chat_id_hash, text, last_error, attempts, failed_at, lane, outcome,
         inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, '{:rate_limited, 1}', 5, now(), 'safe', 'failed',
              now(), now())
      """,
      [String.duplicate("b", 64), text]
    )
  end

  test "clears every stored reply body and keeps the rows" do
    insert_legacy_row!("respuesta clínica uno")
    insert_legacy_row!("respuesta clínica dos")

    assert :ok = Migration.clear_plaintext_text!(Repo)

    %{rows: rows} =
      Repo.query!("SELECT text, chat_id_hash, lane FROM foundation_outbound_dead_letters")

    assert length(rows) == 2

    assert Enum.all?(rows, fn [text, hash, lane] ->
             is_nil(text) and is_binary(hash) and lane == "safe"
           end)
  end
end
