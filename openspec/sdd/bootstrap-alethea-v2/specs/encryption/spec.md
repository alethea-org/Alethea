# Encryption Foundation Specification

## Purpose

Defines the KEK/DEK envelope encryption primitive for Alethea, as a v2 contract parallel to the legacy `Alethea.Encryption.PatientVault` / `Alethea.Encryption.ProfessionalKek`. The primitive supports **cryptographic erasure** (per `UBIQUITOUS_LANGUAGE.md` and the archived issue 001): destroying the DEK record makes the patient's data irrecoverable.

This spec covers the function contract and typespecs only. It does NOT integrate with any schema — that wiring belongs to the future `encryption-integration-foundation` change.

## Requirements

### Requirement: KEK Module Shape

The system MUST provide `Alethea.Foundation.Encryption.KEK` as a module that exposes three functions plus a typespec'd error tuple.

```elixir
@type dek :: binary()  # 32 raw bytes
@type kek :: binary()  # 32 raw bytes

@spec generate() :: kek
@spec wrap(dek(), kek()) :: {:ok, wrapped :: binary()} | {:error, :invalid_kek | :invalid_dek}
@spec unwrap(wrapped :: binary(), kek()) :: {:ok, dek()} | {:error, :invalid_kek | :corrupted | :version_mismatch}
```

The `wrap/2` function MUST return a self-describing binary (the IV is prefixed to the ciphertext, and the version byte is the first byte). The `unwrap/2` function MUST reject any wrapped blob whose version byte is not in the supported set.

#### Scenario: Round-trip of wrap and unwrap recovers the original DEK

- GIVEN a fresh KEK from `generate/0` and a fresh DEK from `generate/0`
- WHEN `wrap(dek, kek)` is called and then `unwrap(wrapped, kek)` is called with the result
- THEN the unwrapped binary equals the original DEK byte-for-byte

#### Scenario: Unwrap with the wrong KEK fails

- GIVEN a wrapped DEK encrypted with KEK A
- WHEN `unwrap(wrapped, kek_b)` is called
- THEN the result is `{:error, :corrupted}` (not `{:ok, _}`)
- AND no plaintext DEK is returned

#### Scenario: Unwrap of a tampered ciphertext fails

- GIVEN a wrapped DEK
- WHEN one byte in the middle of the wrapped binary is flipped
- AND `unwrap(tampered, kek)` is called
- THEN the result is `{:error, :corrupted}`

#### Scenario: Generate always returns 32 bytes of high-entropy data

- GIVEN `generate/0` is called N times (N >= 100)
- WHEN the outputs are concatenated and inspected
- THEN each output is exactly 32 bytes long
- AND no two consecutive outputs are equal (collision check, not exhaustive)

#### Scenario: Wrap with an empty KEK fails

- GIVEN `kek == <<>>` (empty binary)
- WHEN `wrap(dek, kek)` is called
- THEN the result is `{:error, :invalid_kek}`

#### Scenario: Wrap with an empty DEK fails

- GIVEN `dek == <<>>`
- WHEN `wrap(dek, kek)` is called
- THEN the result is `{:error, :invalid_dek}`

### Requirement: KEK Lifecycle (Generators, Not Storage)

The `generate/0` function is the **only** way this module creates a key. The module MUST NOT persist keys, MUST NOT read from the database, and MUST NOT depend on `Application.get_env` for any value other than the cipher configuration (which the future integration change may set, but this spec marks it as not required for compilation of the skeleton).

#### Scenario: The module is pure and side-effect-free

- GIVEN the module is loaded with no application env configured
- WHEN `generate/0`, `wrap/2`, and `unwrap/2` are called
- THEN no calls are made to the database, the file system, or the network
- AND each call returns the contractually correct tuple

### Requirement: Versioning on the Wrapped Format

The wrapped binary format MUST include a version byte at offset 0 to allow future rotation. The first shipped version is `0x01`. The `unwrap/2` function MUST return `{:error, :version_mismatch}` when the version byte is not in the supported set (e.g., a future `:v2` blob given to a v1 decoder).

#### Scenario: A wrapped blob with version 0x99 is rejected

- GIVEN a hand-crafted binary starting with `<<0x99, ...>>` is passed to `unwrap/2`
- WHEN `unwrap(blob, kek)` is called
- THEN the result is `{:error, :version_mismatch}`

#### Scenario: A wrapped blob produced by this module has version 0x01

- GIVEN a successful `wrap(dek, kek)` call
- WHEN the first byte of the result is inspected
- THEN it equals `0x01`

### Requirement: No Integration with Schemas in This Change

The `Alethea.Foundation.Encryption.KEK` module MUST NOT import any Ecto schema, MUST NOT be called by `Alethea.Accounts.create_patient/2` or any legacy module, and MUST NOT have any `belongs_to` or `has_many` associations. It is a pure crypto primitive.

#### Scenario: The module does not depend on Ecto

- GIVEN `lib/alethea/foundation/encryption/kek.ex` is loaded
- WHEN the file is read
- THEN it does NOT contain `use Ecto.Schema`
- AND it does NOT contain `belongs_to` or `has_many`
- AND the file does NOT import any submodule of `Alethea.Accounts`
