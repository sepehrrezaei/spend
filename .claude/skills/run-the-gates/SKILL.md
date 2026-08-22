---
name: run-the-gates
description: Run the checks CI runs, in the order CI runs them, before opening a PR or claiming work is done. Use before any push, before reporting a fix complete, and when a CI check fails.
source: earned — format runs before tests in CI, so a formatting slip means no test ever runs
confidence: high
---

# Run the gates

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos
flutter test
flutter test -d macos integration_test
```

Xcode may need `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Why in that order

CI runs formatting **first**, then analyse, then test. A formatting slip fails the job
before a single test executes, so a green local `flutter test` tells you nothing about
whether CI will pass.

`--fatal-infos` is not optional. A lint that is merely an info locally is a red check
remotely.

## What the gates do not cover

`analysis_options.yaml` is stock `flutter_lints` with no custom rules. **Nothing
mechanical enforces the five rules in CLAUDE.md** — not integer money, not `Day` over
`DateTime`, not the model-never-computes boundary. A change can violate all of them and
go green.

So when reporting a review, say what the gates said. "Six violations, and CI is green" is
the sentence that tells a reader how much weight the review is carrying.

## Reading a failed check

Read the log before theorising. Build-time warnings from Xcode and the HotKey pod appear
in **every** job, including ones that have always been green — compare against the
`Build macOS app` job before calling something new.

A job that is `cancelled` after ~20 minutes is the timeout, which means something hung
rather than failed. That has happened here: a failing end-to-end test left the app alive
because `preventClose` was never lifted, and `flutter test` waited on a process that
would never exit.
