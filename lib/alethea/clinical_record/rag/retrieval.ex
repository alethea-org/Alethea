defmodule Alethea.ClinicalRecord.Rag.Retrieval do
  @moduledoc """
  Read-side of the non-authoritative, patient-scoped semantic
  projection (sdd/clinical-rag-projection, GitHub #196, WU4). Not wired
  to any caller yet — the LiveView surface (WU5) calls `search/4`; this
  module is an independently testable unit in this batch, same pattern
  as WU2's `Indexer`.

  ## Flow (design section 5)

  `search/4` authorizes via `Accounts.get_patient_for_professional/2`
  (the same accessor every other patient-scoped `ClinicalRecord`
  surface uses — spec's Access Control requirement), loads the
  professional's KEK and the patient's DEK, embeds the query, runs a
  patient-scoped ANN query capped at `:candidate_limit` (default 50),
  decrypts strictly that already-limited candidate set (never the
  whole table — see "Security boundary" below), lexically rescores
  each decrypted candidate against the query, merges dense + lexical
  into one score, sorts, and truncates to `:limit` (default 10).

  ## Security boundary: decrypt happens strictly AFTER the SQL LIMIT

  `fetch_candidates/3` issues one SQL query that already carries
  `LIMIT :candidate_limit` — Postgres, not this module, is what bounds
  the row set before a single byte is decrypted. `score_candidate/5`
  then hard-matches `PatientVault.decrypt/2`'s result: a decrypt
  failure on an already-limited candidate is treated as a fail-loud
  integrity error (raises), not a silently-dropped result. There is no
  caller yet, so this is safe to keep strict; a future caller may
  choose to catch and log instead, but it must never do so by
  decrypting the unlimited table first.

  ## Cross-patient isolation

  Enforced structurally: `fetch_candidates/3`'s WHERE clause scopes by
  `patient_id` before the ANN `ORDER BY`/`LIMIT` ever runs, so no
  amount of adversarial query crafting can pull another patient's rows
  into the candidate set — see the spec's "Cross-patient query never
  leaks" scenario.

  ## Lexical normalization + score merge (design section 5)

  `normalize/1`: downcase → NFD (`:unicode.characters_to_nfd_binary/1`)
  → strip combining marks (accent fold) → strip punctuation → split →
  drop Spanish stopwords. `lexical_score/2`: fraction of the query's
  normalized content tokens present in the candidate text, plus a flat
  bonus when the accent-folded query phrase appears verbatim (cheap,
  interpretable, deliberately not `String.jaro_distance` — see design
  section 5's rejection rationale). `merge_score/3`:
  `dense_weight * (1 - dense_distance) + lexical_weight * lexical`,
  weights overridable via `opts` so tuning never needs a migration.

  ## Freshness (design section 5)

  `freshness/1` runs ONE query over `oban_jobs` (mirrors
  `AletheaJobs.SessionReminderWorker.cancel_pending/1`'s established
  fragment pattern) rather than comparing a `last_indexed_at` — there
  is no single per-patient last-write timestamp across the 5 source
  tables + draft upsert.
  """

  import Ecto.Query
  import Pgvector.Ecto.Query, only: [cosine_distance: 2]

  alias Alethea.Accounts
  alias Alethea.Accounts.Professional
  alias Alethea.AI
  alias Alethea.ClinicalRecord.Rag.Chunk
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo

  @candidate_limit 50
  @default_limit 10
  @dense_weight 0.7
  @lexical_weight 0.3
  @phrase_bonus 0.2

  @outbox_worker "AletheaJobs.ClinicalRecordOutboxWorker"
  @pending_states ~w(available scheduled executing retryable)

  @spanish_stopwords MapSet.new(~w(
    a al algo algunas algunos ante antes como con contra cual cuando de del desde donde
    durante e el ella ellas ellos en entre era erais eramos eran eras eres es esa esas ese
    esos esta estaba estabais estabamos estaban estabas estad estada estadas estado estados
    estais estamos estan estar estara estare estas este esto estos estoy fue fuera fuerais
    fueramos fueran fueras fueron fuese fueseis fuesemos fuesen fueses fui fuimos ha habeis
    habia habiais habiamos habian habias habida habidas habido habidos habiendo han has hasta
    hay he hemos hube hubierais hubieramos hubieran hubieras hubieron hubiese hubieseis
    hubiesemos hubiesen hubieses hubimos hubiste hubisteis hubo la las le les lo los mas me
    mi mia mias mientras mio mios mis mucho muchos muy nada ni no nos nosotras nosotros nuestra
    nuestras nuestro nuestros o os otra otras otro otros para pero poco por porque que quien
    quienes que se sea seais seamos sean seas ser sera serán sereis seremos seria seriais
    seriamos serian serias si sido siendo sin sobre sois somos son soy su sus suya suyas suyo
    suyos tambien tanto te tendra tendran tenéis tenemos tenga tengo tenia teniais teniamos
    tenian tenias ti tiene tienen tienes todo todos tu tus tuya tuyas tuyo tuyos un una uno
    unos vosostras vosotros vuestra vuestras vuestro vuestros y ya yo
  ))

  @type result :: %{
          chunk_id: Ecto.UUID.t(),
          source_resource_type: String.t(),
          source_resource_id: Ecto.UUID.t(),
          source_occurred_at: DateTime.t(),
          target_behavior_id: Ecto.UUID.t() | nil,
          chunk_index: non_neg_integer(),
          full_event: boolean(),
          content: String.t(),
          dense_distance: float(),
          lexical_score: float(),
          score: float()
        }

  @type envelope :: %{
          results: [result()],
          chunk_count: non_neg_integer(),
          freshness: %{stale?: boolean(), pending: non_neg_integer()}
        }

  # --- 5.7/5.8 authz + top-level search/4 -------------------------------

  @doc """
  Authorizes `professional` against `patient_id` via the existing
  `Accounts.get_patient_for_professional/2` accessor — the same check
  every other patient-scoped `ClinicalRecord` surface uses (spec's
  Access Control requirement) — then embeds `query`, runs the
  candidate-limited ANN + lexical rescore, and returns the merged
  envelope.

  `opts`:
  - `:candidate_limit` (default #{@candidate_limit}) — ANN window size,
    decrypted/rescored in full before truncation to `:limit`.
  - `:limit` (default #{@default_limit}) — final result count after
    scoring.
  - `:dense_weight` / `:lexical_weight` (defaults #{@dense_weight} /
    #{@lexical_weight}) — merge weights.
  """
  @spec search(Professional.t(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, envelope()} | {:error, :unauthorized | term()}
  def search(%Professional{} = professional, patient_id, query, opts \\ [])
      when is_binary(patient_id) and is_binary(query) do
    case Accounts.get_patient_for_professional(professional.id, patient_id) do
      nil ->
        {:error, :unauthorized}

      patient ->
        with {:ok, kek} <- Accounts.load_professional_kek(professional),
             {:ok, dek} <- Accounts.load_patient_dek(patient, kek) do
          do_search(patient, dek, query, opts)
        end
    end
  end

  defp do_search(patient, dek, query, opts) do
    candidate_limit = Keyword.get(opts, :candidate_limit, @candidate_limit)
    result_limit = Keyword.get(opts, :limit, @default_limit)
    dense_weight = Keyword.get(opts, :dense_weight, @dense_weight)
    lexical_weight = Keyword.get(opts, :lexical_weight, @lexical_weight)

    with {:ok, query_vector} <- embed_query(query) do
      results =
        patient.id
        |> fetch_candidates(query_vector, candidate_limit)
        |> Enum.map(&score_candidate(&1, query, dek, dense_weight, lexical_weight))
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(result_limit)

      {:ok,
       %{
         results: results,
         chunk_count: count_chunks(patient.id),
         freshness: freshness(patient.id)
       }}
    end
  end

  defp embed_query(query) do
    case AI.embeddings().embed(query, []) do
      {:ok, vector} -> {:ok, vector}
      {:error, _reason} = error -> error
    end
  end

  # --- 5.3/5.4 candidate fetch (patient-scoped ANN, LIMIT before decrypt) --

  # The WHERE clause scopes by `patient_id` BEFORE the ANN `ORDER BY`/
  # `LIMIT` ever runs (cross-patient isolation is structural, not a
  # post-filter), and `limit/2` bounds the row set Postgres returns —
  # `score_candidate/5` (the only caller that decrypts) only ever sees
  # rows already inside this window. See the moduledoc's "Security
  # boundary" section.
  defp fetch_candidates(patient_id, query_vector, candidate_limit) do
    Chunk
    |> where([c], c.patient_id == ^patient_id)
    |> select([c], %{chunk: c, dense_distance: cosine_distance(c.embedding, ^query_vector)})
    |> order_by([c], cosine_distance(c.embedding, ^query_vector))
    |> limit(^candidate_limit)
    |> Repo.all()
  end

  defp count_chunks(patient_id) do
    Chunk
    |> where([c], c.patient_id == ^patient_id)
    |> Repo.aggregate(:count)
  end

  defp score_candidate(
         %{chunk: chunk, dense_distance: dense_distance},
         query,
         dek,
         dense_weight,
         lexical_weight
       ) do
    # Hard match, deliberately: a decrypt failure on an already
    # candidate-limited row is an integrity error, not a result to
    # silently drop (see moduledoc). `dense_distance` comes back from
    # Postgres as a plain float (pgvector `<=>` is `double precision`).
    {:ok, content} = PatientVault.decrypt(chunk.encrypted_content, dek)

    lexical = lexical_score(query, content)

    score =
      merge_score(dense_distance, lexical,
        dense_weight: dense_weight,
        lexical_weight: lexical_weight
      )

    %{
      chunk_id: chunk.id,
      source_resource_type: chunk.source_resource_type,
      source_resource_id: chunk.source_resource_id,
      source_occurred_at: chunk.source_occurred_at,
      target_behavior_id: chunk.target_behavior_id,
      chunk_index: chunk.chunk_index,
      full_event: chunk.full_event,
      content: content,
      dense_distance: dense_distance,
      lexical_score: lexical,
      score: score
    }
  end

  # --- 5.5/5.6 freshness --------------------------------------------------

  @doc """
  `%{stale?: bool, pending: n}` from ONE query over `oban_jobs`, scoped
  to this worker's queue, the pre-run/in-flight/retry states, and this
  patient's `args->>'patient_id'` (mirrors
  `AletheaJobs.SessionReminderWorker.cancel_pending/1`'s established
  fragment pattern).
  """
  @spec freshness(Ecto.UUID.t()) :: %{stale?: boolean(), pending: non_neg_integer()}
  def freshness(patient_id) do
    pending =
      Oban.Job
      |> where([j], j.worker == ^@outbox_worker)
      |> where([j], j.state in ^@pending_states)
      |> where([j], fragment("? ->> 'patient_id' = ?", j.args, ^to_string(patient_id)))
      |> Repo.aggregate(:count)

    %{stale?: pending > 0, pending: pending}
  end

  # --- 5.1 lexical normalization ------------------------------------------

  @doc """
  Downcase → NFD → strip combining marks (accent fold) → strip
  punctuation → split on whitespace → drop Spanish stopwords. Returns
  the list of remaining content tokens.
  """
  @spec normalize(String.t()) :: [String.t()]
  def normalize(text) when is_binary(text) do
    text
    |> fold()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.reject(&MapSet.member?(@spanish_stopwords, &1))
  end

  # Downcase + NFD accent-fold only (keeps stopwords and punctuation) —
  # used by `lexical_score/2`'s exact-phrase check, which must compare
  # against the query's literal word order, not its stopword-filtered
  # token set.
  defp fold(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
  end

  # --- 5.2 lexical score + score merge ------------------------------------

  @doc """
  Fraction of `query`'s normalized content tokens present anywhere in
  `text`, plus a flat #{@phrase_bonus} bonus when the accent-folded
  `query` phrase appears verbatim inside `text`, clamped to `1.0`. An
  empty (all-stopword) query has no content tokens to cover and scores
  `0.0`.
  """
  @spec lexical_score(String.t(), String.t()) :: float()
  def lexical_score(query, text) when is_binary(query) and is_binary(text) do
    query_tokens = normalize(query) |> Enum.uniq()
    text_tokens = text |> normalize() |> MapSet.new()

    coverage =
      case query_tokens do
        [] ->
          0.0

        tokens ->
          matched = Enum.count(tokens, &MapSet.member?(text_tokens, &1))
          matched / length(tokens)
      end

    phrase_bonus = if exact_phrase?(query, text), do: @phrase_bonus, else: 0.0

    min(coverage + phrase_bonus, 1.0)
  end

  defp exact_phrase?(query, text) do
    folded_query = query |> fold() |> String.trim()
    folded_query != "" and String.contains?(fold(text), folded_query)
  end

  @doc """
  `dense_weight * (1 - dense_distance) + lexical_weight * lexical`.
  Weights default to #{@dense_weight}/#{@lexical_weight} and are
  overridable via `opts` (`:dense_weight`, `:lexical_weight`) so tuning
  never needs a migration.
  """
  @spec merge_score(float(), float(), keyword()) :: float()
  def merge_score(dense_distance, lexical, opts \\ [])
      when is_number(dense_distance) and is_number(lexical) do
    dense_weight = Keyword.get(opts, :dense_weight, @dense_weight)
    lexical_weight = Keyword.get(opts, :lexical_weight, @lexical_weight)

    dense_weight * (1 - dense_distance) + lexical_weight * lexical
  end
end
