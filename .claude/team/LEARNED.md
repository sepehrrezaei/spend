# Learned

Append-only. Things this team got wrong once and should not get wrong again.

A skill or a rule elsewhere in `.claude/` is the *policy*; this file is the *evidence*.
Every entry names the incident, because a rule without its origin gets deleted by the
next person who finds it inconvenient.

Add an entry when a correction lands — yours or a reviewer's. Do not add speculation.

---

### A test that has never failed has not been tested
Three tests written here passed while asserting nothing: a wait for a row already on
screen, a wait for a row to disappear that was satisfied mid-query, and a 1ms timeout
racing real plugin calls. Each was caught only by breaking the code they guarded.
→ `verify-by-breaking`

### The fix is where the next bug lives
Two consecutive PRs shipped a defect *inside* the fix for the previous defect. An
autoDispose fix introduced a spinner on every search; a hang fix silently unregistered
the global hotkey. Both were reviewed by their own author and declared done.
→ `review-protocol`, author lockout

### A confident comment is a reason to look harder
A trial against disguised violations found four comments defending broken code. **None
was accurate.** One argued a `double` signature avoided allocation when it forces more;
one claimed the chart axis wants a `DateTime` when the app's only chart axes off `Day`;
one justified a cap on "suggestions" for a query that caps rows.

### Green CI proves less here than it looks
`analysis_options.yaml` is stock `flutter_lints`. Six deliberate rule violations —
including `fold(0.0, ...)` over amounts and minor units crossing into a prompt — passed
`dart format`, `flutter analyze --fatal-infos` and the full suite.

### A killed command does not clean up after itself
A deliberate sabotage survived a timeout and sat in the working tree unnoticed, because
the cleanup line never ran. Check `git diff` after any deliberate break.

### A gate that hangs is not a gate
The first end-to-end suite did not fail on a broken restore — it ran 20 minutes and came
back `cancelled`, because pumping the app set `preventClose` and nothing lifted it.
Twenty minutes of ambiguity reads as flakiness, and people re-run rather than investigate.

### Measure the layout, do not estimate it
A breakpoint set by eye at 730 needed 963. The screenshot that "proved" it worked was
taken with "August 2026" in the label; "September 2026" would have clipped.

### The agent files needed testing as much as the code
The first version of this team was written confidently and read well. A trial run found
`money-guard`'s scope excluded `lib/data`, where the worst planted violation was, and
`security-reviewer` nearly reported a LIKE bug at the wrong severity.
