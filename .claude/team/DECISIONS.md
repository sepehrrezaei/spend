# Decisions

Questions that reached the human, and the answer. Append-only.

A decision nobody wrote down gets relitigated by whoever next finds it inconvenient — and
an agent that cannot see the answer will cheerfully re-derive the wrong one.

Record: what was asked, what was decided, and what would change it.

---

### Branch protection is two rulesets, not one
**Asked:** should required checks and required review live in one ruleset?
**Decided:** no — split. Bypass applies to a whole ruleset, so a single ruleset would let
an admin bypassing the review requirement also bypass the status checks, and merge red CI.
**Now:** "Green CI and a PR, no exceptions" has **no** bypass actors; "Maintainer approval
for contributions" allows admins.
**Would change it:** a second maintainer joining, at which point the admin bypass could go.

### The owner may self-merge; nobody may merge red
**Asked:** the review rule can never be satisfied on a solo repo — GitHub forbids
approving your own PR at any permission level. Drop it, or allow bypass?
**Decided:** keep review at 1 with admin bypass, because the project is open-source and
contributions should need a maintainer. The owner merges their own work via bypass, which
GitHub records.

### Multi-currency stays out
**Asked:** worth adding?
**Decided:** not without a design that survives the offline promise. Exchange rates need
the network, and the whole premise is that the app works with none. Also surgery on
`Money`, the most safety-critical type here.
**Would change it:** manually entered rates stored per transaction, so a converted amount
is a fact rather than a live calculation.

### Signing and notarisation are unresolved
**Asked:** pay for a Developer ID?
**Decided:** deferred. Costs €99/year, which was deliberately avoided. Until then the app
is ad-hoc signed and a downloaded release will not open — so "build from source" is the
only supported path and the README must say so rather than teaching a Gatekeeper bypass.

### Squad was evaluated and not adopted
**Asked:** use bradygaster/squad for the agent team?
**Decided:** no — it targets GitHub Copilot, is alpha, and installs 173 files whose
charters know nothing about this project's rules. Its architecture was worth taking:
skills separate from roles, provenance on every rule, reviewer lockout, persistent
per-agent memory. This directory is that architecture, Claude-native and project-specific.
