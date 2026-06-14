# SDD Proposal: KEK Ownership Validation

## Change Name
`auth-kek-ownership-validation`

## Problem Statement
Currently, when a professional authenticates, the KEK is loaded into the LiveView socket without verifying that the `professional_id` in the session actually owns the KEK being loaded. This creates a theoretical vulnerability where session manipulation could allow access to another professional's KEK.

## Proposed Solution
Add validation that the `professional_id` in the session matches the `professional_id` associated with the KEK being loaded. If mismatch detected, reject the mount and redirect to login.

## Scope
- `lib/alethea_web/plugs/professional_auth.ex`
- `lib/alethea/encryption/professional_kek.ex` (may need read)

## Constraints
- Must not break existing auth flow for legitimate users
- KEK files are stored per-professional, so validation is feasible
- Session manipulation is theoretical (no evidence of exploitation)

## Success Criteria
- [ ] Session with wrong professional_id cannot load KEK
- [ ] Legitimate sessions continue to work unchanged
- [ ] Audit log entry created on KEK access attempt
- [ ] All existing tests pass

## Risks
- Low: This is a defense-in-depth measure
- Performance: Minimal (one file existence check)

## Alternatives Considered
1. **Skip validation**: Rejected - security best practices require verification
2. **Re-architect KEK storage**: Too expensive for this issue, better for future

## Rollback Plan
- If issues arise, remove the assertion from `on_mount`
- Original behavior restored immediately

---

**Status**: PROPOSED
**Author**: el Gentleman
**Created**: 2026-06-01
**Related Issue**: 007-tech-debt-business-logic-fixes.md → T1