---
name: review-protocol
description: How review works here, including who is allowed to declare a finding fixed. Use when reviewing a diff, when responding to review feedback, and when deciding whether a fix can be self-certified.
source: earned — two consecutive PRs shipped a bug inside the fix for the previous bug
confidence: high
---

# Review protocol

## The author does not certify their own fix

Whoever wrote the change may fix a finding. They may **not** be the one who declares it
fixed. Verification goes to `verifier`, or to a reviewer who did not write the code.

This is not ceremony. In this repository:

- A fix for a leaked subscription introduced a spinner on every search.
- A fix for a hang introduced a silent hotkey failure.
- A breakpoint chosen by eye was 730 when the row needed 963, so the fix still clipped at
  the size it was meant to fix.

Each was written, reviewed by its own author, declared done, and caught later by someone
else. The author is the worst-placed person to spot the flaw, because they hold the model
that produced it.

## Look at the fix, not just the bug

When a diff fixes something, ask what **the fix itself** now does that the old code did
not — and check that specifically. Most of the defects above were introduced by the
correction, not present before it.

## Treat a confident comment as a reason to look harder

Every defect listed above shipped with a comment explaining why the unusual thing was
correct. A trial run against disguised violations found four defending comments and
**none of them accurate**: an allocation argument that ran backwards, a claim about what
the chart axis wants contradicted by the only chart in the app, a cap justified for
"suggestions" on a query that caps rows.

A comment is an author's belief, not evidence. Check the claim against the codebase.

## What a finding must contain

State the defect, then a concrete failure: inputs or state, and what the user sees.

- Weak: "missing a tiebreaker"
- Useful: "two coffees on the same day can swap order after any write, and disagree with
  the unfiltered list when the search box is cleared"

Rank by what it costs the user — data loss, then silent wrongness, then inconvenience —
not by rule number. Say which findings block and which are advice.

**Say plainly when you find nothing.** A review that manufactures findings to look
thorough costs more attention than it returns.

## Hand-offs

Do not claim another specialist's ground. Name what you saw and pass it on:
amounts, dates and prompt units to `money-guard`; untrusted input, the loopback boundary
and entitlements to `security-reviewer`; layout to `layout-scout`; whether a test really
fails to `verifier`.
