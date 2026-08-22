---
name: verify-by-breaking
description: Prove a test actually catches the bug it claims to, by breaking the code and watching it go red. Use before declaring any fix done, whenever a test is added alongside a bug fix, and whenever a test's assertion could be satisfied by a transient state.
source: earned — three tests in this repo passed while asserting nothing
confidence: high
---

# Verify by breaking

A test that has never failed has not been tested.

## The method

1. Read the test and the code it guards. Find the smallest change that should break it.
2. Make that change — prefer reverting the fix itself over inventing a new bug. The
   question is whether the test catches *this* regression.
3. Run the suite. Record which tests fail, and how many.
4. **Restore the code, then confirm with `git diff` that it is restored.**
5. Report what happened, including any test that did *not* fail when you expected it to.

## Ways a test passes while asserting nothing

Each of these happened here.

- **Waiting for something already on screen.** Returns on the first frame, before the
  behaviour under test has run. The search test waited for a row that was already
  rendered and passed before the 250ms debounce fired.
- **Waiting for something to disappear.** Satisfied by the transient frame where a list
  is mid-query and empty, so it returns before the new state arrives. Wait on the
  *conjunction* — the new thing present and the old thing gone.
- **A short timeout racing real work.** A 1ms window timeout against real plugin calls
  is a race; on a fast host the calls win and the fallback path is never taken. Inject a
  future that never completes instead, and assert elapsed time.
- **A log line from one run.** Proves the path executed once. It does not stop the path
  being skipped on another machine.

## Cautions in this repository

- Touching `lib/` forces a full macOS rebuild, several minutes. Touching only test files
  reuses the build and runs in seconds.
- **A killed command does not undo your sabotage.** A deliberate break once survived a
  timeout and sat in the working tree unnoticed. Check `git diff` after, every time.
- `flutter test` is everything under `test/`; `flutter test -d macos integration_test` is
  the end-to-end suite. A break in `lib/features/settings/data_section.dart` is invisible
  to the first and caught by the second — a useful way to prove the end-to-end layer earns
  its runtime.
