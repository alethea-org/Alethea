# Issue #447 — Tag replies to a Trigger activo as ELICITED
Objective: implement #447 on `feat/447-tag-replies-elicited`, based on `1ac7f4a25032049ba3bb83b0da6d6a546d1bf932`.
Delivery: feature branch commit; forecast ~150 authored changed lines. Runner: focused `mix test` files and `mix precommit`.

## Specs
S1. "A reply within 2h is ELICITED; after 2h it is SPONTANEOUS." Check patient reply within 2 hours of a delivered active trigger is tagged "elicited"; after 2 hours it is tagged "spontaneous".
S2. "Only delivered trigger messages open the window." Check that undelivered trigger messages (pending, failed, ambiguous) and non-trigger messages do not open the elicited window.

## Tasks
- T1 | S1, S2 | inline | done | Implemented `Triggers.elicited_window_open?/2` (sent-only anchor, newest-by-timestamp, inclusive 2h boundary) and inbound tagging in `Clinical.find_or_save_telegram_inbound/4` on first insert only. RED: 14 failures (13 unit UndefinedFunctionError + 1 worker tag mismatch; 2 worker guard tests pinned current behavior). GREEN: focused 110 passed; full suite and precommit 2637 passed, 5 skipped. Commit c7919a6 on `feat/447-tag-replies-elicited` (387 authored changed lines).

## Log
L1. User request verbatim: "hagamos la issue [Feature]: Tag replies to a Trigger activo as ELICITED #447"
L2. Issue #447 body verbatim:
> ## Parent
>
> #435
>
> ## What to build
>
> A patient message received within 2h of a delivered Trigger activo message is tagged ELICITED instead of SPONTANEOUS, so the clinical record distinguishes prompted from spontaneous behavior.
>
> ## Acceptance criteria
>
> - A reply within 2h is ELICITED; after 2h it is SPONTANEOUS.
> - Only delivered trigger messages open the window.
>
> ## Blocked by
>
> - #440
L3. #440 is closed. Branch `feat/447-tag-replies-elicited` created from latest `origin/main` (1ac7f4a25032049ba3bb83b0da6d6a546d1bf932). Full test suite clean (2621 passed, 5 skipped).
L4. Implementation interpretations (documented, deterministic, no extra product feature): window is inclusive at exactly 2h and at delivery instant (elapsed in [0, 7200] seconds); "delivered" means Telegram-acknowledged `delivery_state: "sent"` — pending, ambiguous, failed never open the window; when several delivered trigger messages exist the newest by `(timestamp, id)` anchors the window and a newer pending row does not mask it; a reply timestamped before the delivery is outside; gate is per-patient; nil-timestamp legacy inbounds are spontaneous; the gate runs only on first insert (resumed rows keep their persisted tag) and is evaluated against the wall clock milliseconds before the row's own second-truncated timestamp (accepted sub-second skew, documented in the doc). Docs: `docs/development/one-shot-triggers.md` gained section 9 and #447 left the exclusions list. No migration, no DB change, no schema change.
