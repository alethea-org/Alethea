# SDD Spec: KEK Ownership Validation

## Change: `auth-kek-ownership-validation`

---

## Functional Requirements

### FR-1: KEK File Ownership Verification
**Given** a professional has authenticated with `professional_id` in session
**When** the LiveView mounts and attempts to load the KEK
**Then** the system must verify that the KEK file stored at `keks/{professional_id}.key` belongs to that professional
**And** if verification fails, redirect to `/login` with error flash

### FR-2: Audit Trail on KEK Access
**Given** a professional mounts any protected LiveView
**When** the KEK is successfully loaded
**Then** an audit log entry must be created with:
- `action`: `"KEK_ACCESS"`
- `professional_id`: the authenticated professional's ID
- `details`: ` %{keks_path: "keks/{id}.key"}`

### FR-3: Graceful Failure
**Given** KEK file is missing or corrupted
**When** a professional tries to mount a protected LiveView
**Then** redirect to `/login` with flash message: `"Sesión inválida. Por favor, iniciá sesión nuevamente."`
**And** log the error for debugging

---

## Non-Functional Requirements

### NFR-1: Performance
- KEK validation must add < 5ms to mount time
- Use file existence check, not full file read validation

### NFR-2: Compatibility
- Must work with existing session structure
- No changes to login flow required

### NFR-3: Security
- Never expose KEK in error messages
- Never log the actual KEK content

---

## Scenarios

### Scenario 1: Valid Session, KEK Exists
```
Setup: Professional "Dr. Smith" (id: abc123) has KEK at keks/abc123.key
Action: Dr. Smith logs in and navigates to /dashboard
Expected:
  - KEK loads successfully
  - Audit log entry created
  - Dashboard renders normally
Result: PASS
```

### Scenario 2: Session Manipulation Attempt
```
Setup: Attacker has session with professional_id=abc123 but KEK belongs to professional xyz456
Action: Attacker navigates to /dashboard
Expected:
  - System detects mismatch (file keks/abc123.key doesn't exist)
  - Redirect to /login
  - No KEK loaded
  - Error logged
Result: PASS
```

### Scenario 3: Missing KEK File
```
Setup: Professional exists but KEK file was accidentally deleted
Action: Professional logs in
Expected:
  - Redirect to /login
  - Flash message displayed
Result: PASS
```

### Scenario 4: Corrupted KEK File
```
Setup: KEK file exists but contains invalid data
Action: Professional logs in
Expected:
  - Attempt to decrypt/validate KEK fails
  - Redirect to /login
  - Flash message displayed
Result: PASS
```

---

## Data Structures

### AuditLog Entry (new action)
```elixir
%{
  action: "KEK_ACCESS",
  professional_id: "abc123",
  resource_type: "KEK",
  resource_id: nil,
  details: %{
    keks_path: "keks/abc123.key",
    result: :success | :not_found | :invalid
  },
  inserted_at: ~U[2026-06-01T00:00:00Z]
}
```

---

## Acceptance Criteria Checklist

- [ ] **AC-1**: Valid sessions with matching KEK load without error
- [ ] **AC-2**: Session mismatch redirects to login
- [ ] **AC-3**: Missing KEK file redirects to login with flash
- [ ] **AC-4**: Corrupted KEK redirects to login with flash
- [ ] **AC-5**: All KEK access attempts are logged to audit_logs
- [ ] **AC-6**: Error messages don't expose KEK content
- [ ] **AC-7**: Performance: mount time < 100ms
- [ ] **AC-8**: All existing tests pass
- [ ] **AC-9**: No changes to login flow required

---

## Implementation Notes

### Files to Modify
1. `lib/alethea_web/plugs/professional_auth.ex` - Add ownership validation in `on_mount`
2. `lib/alethea/encryption/professional_kek.ex` - Add helper function `verify_kek_exists/1`

### Test Files to Create
1. `test/alethea_web/plugs/professional_auth_test.exs` - Test KEK ownership validation

---

**Status**: SPEC
**Author**: el Gentleman
**Created**: 2026-06-01