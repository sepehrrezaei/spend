---
name: merge-order
description: This repository's branch protection, and the ordering traps in changing it. Use before opening a PR, when a merge is blocked, and for anything touching CI or the rulesets.
source: earned — a required check that has never reported blocks every merge
confidence: high
---

# Merge order

## Two rulesets, deliberately split

Bypass applies to a whole ruleset, never a single rule. That is why there are two.

| Ruleset | Bypass | Enforces |
|---|---|---|
| Green CI and a PR, no exceptions | **nobody** | PR required, all three checks green, linear history |
| Maintainer approval for contributions | admins | one approving review |

An outside contributor needs review **and** green CI. The owner can self-merge past the
review, but **nobody can merge red CI, including admins**. If you are tempted to add a
bypass to the first ruleset, escalate instead.

GitHub does not allow approving your own pull request, at any permission level. An owner
merging their own work uses the admin bypass, which GitHub records.

## Changing the rules

- **A required status check that has never reported blocks every merge.** Land the
  workflow, let it go green on `main`, then require it.
- **Never guess a check name.** Read them from
  `gh api repos/:owner/:repo/commits/main/check-runs`.
- **`PUT` on a ruleset replaces the entire rules array.** Fetch the current one and
  re-send every rule you are not deliberately changing, or you will silently drop one.

## Order of work

Land the change that others describe before the description. When a docs PR explains
behaviour that a code PR is still changing, merge the code first so the docs describe
what shipped.
