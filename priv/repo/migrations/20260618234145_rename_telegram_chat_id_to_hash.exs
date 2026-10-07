defmodule Alethea.Repo.Migrations.RenameTelegramChatIdToHash do
  @moduledoc """
  Renames `foundation_patients.telegram_chat_id` (raw chat_id) to
  `foundation_patients.telegram_chat_id_hash` (HMAC-SHA256 of the chat_id
  with the project pepper) and adds a partial unique index that
  enforces "at most one patient per hash" while allowing the column
  to remain `NULL` for not-yet-onboarded patients.

  Per `REQ-C2-chat-id-stored-as-hmac`, the system never stores,
  queries, or logs a raw `chat_id`. Per `REQ-C2-partial-unique-index`,
  the lookup key is a hash, the uniqueness is enforced at the DB
  layer, and the column is `null: true` (a patient may exist before
  they `/start` the bot).

  ## Backfill

  If any pre-existing row has `telegram_chat_id` populated, the
  backfill computes the hash using
  `Application.get_env(:alethea, :telegram_chat_id_pepper)`. If the
  pepper is unset, the backfill is a no-op and a `Logger.warning` is
  emitted: the operator must rotate the pepper manually (per
  ADR-0008). The dev DB has no `telegram_chat_id` rows per the change
  handoff (Q1 evidence), so the no-op path is the production-safe
  default in :dev and :test.

  ## Why a partial unique index (not a plain unique)

  PostgreSQL allows multiple `NULL`s in a plain unique index, but
  the `WHERE telegram_chat_id_hash IS NOT NULL` clause documents the
  intent: the unique constraint applies only to bound chats. New
  patients (no `/start` yet) do not consume a unique slot.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # 1. Add the new column (nullable; a patient may exist pre-onboarding).
    alter table(:foundation_patients) do
      add :telegram_chat_id_hash, :string
    end

    # 2. Backfill: if any row has a raw chat_id, hash it. Skipped when
    #    no pepper is configured (the dev/test default).
    backfill_hashes!()

    # 3. Drop the raw column. The raw chat_id is the PHI surface; it
    #    must not survive the migration.
    alter table(:foundation_patients) do
      remove :telegram_chat_id
    end

    # 4. Partial unique index. At most one patient per hash; multiple
    #    NULL rows are allowed.
    create unique_index(
             :foundation_patients,
             [:telegram_chat_id_hash],
             name: :foundation_patients_telegram_chat_id_hash_unique,
             where: "telegram_chat_id_hash IS NOT NULL"
           )
  end

  def down do
    drop_if_exists(
      unique_index(
        :foundation_patients,
        [:telegram_chat_id_hash],
        name: :foundation_patients_telegram_chat_id_hash_unique,
        where: "telegram_chat_id_hash IS NOT NULL"
      )
    )

    alter table(:foundation_patients) do
      add :telegram_chat_id, :string
    end

    # The reverse backfill is lossy (the hash → chat_id mapping is
    # one-way). On rollback, the column is re-added as `null: true`
    # and no rows are repopulated: the operator must re-onboard
    # affected patients.
    alter table(:foundation_patients) do
      remove :telegram_chat_id_hash
    end
  end

  # Best-effort backfill. Reads the pepper from app env at migration
  # time. If unset, emits a single warning and continues — the dev
  # DB has no pre-existing rows, so the production safety property
  # holds without the backfill.
  defp backfill_hashes! do
    pepper =
      :alethea
      |> Application.get_env(:telegram_chat_id_pepper)
      |> case do
        nil -> nil
        "" -> nil
        value when is_binary(value) and byte_size(value) >= 32 -> value
        _ -> nil
      end

    case pepper do
      nil ->
        require Logger

        Logger.warning(fn ->
          "telegram_chat_id -> hash migration: no pepper configured; skipping backfill"
        end)

      pepper ->
        # The column added above is still queued in the migration runner;
        # the statements below run immediately, so it has to exist first.
        flush()

        # The HMAC is computed here rather than in SQL (`hmac/3` belongs to
        # pgcrypto, which this database does not install) and must stay
        # byte-identical to `Alethea.Telegram.ChatIdHash.hash/2`:
        # HMAC-SHA256 keyed by the pepper over the chat_id, lowercase hex.
        # It is inlined so a later change to that module cannot alter what
        # this migration wrote. `log: false` keeps the chat_id and the hash
        # out of the query log.
        %{rows: rows} =
          repo().query!(
            "SELECT id, telegram_chat_id FROM foundation_patients WHERE telegram_chat_id IS NOT NULL",
            [],
            log: false
          )

        Enum.each(rows, fn [id, chat_id] ->
          hash =
            :hmac
            |> :crypto.mac(:sha256, pepper, chat_id)
            |> Base.encode16(case: :lower)

          repo().query!(
            "UPDATE foundation_patients SET telegram_chat_id_hash = $1 WHERE id = $2",
            [hash, id],
            log: false
          )
        end)
    end
  end
end
