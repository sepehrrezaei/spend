# Screenshots

`icon.png` is generated from the app icon source and is already here.

The rest need capturing by hand — a screenshot tool cannot be driven from CI,
and these want to show real-looking data rather than an empty database.

## What the README expects

| File | Screen | Notes |
|---|---|---|
| `overview.png` | Overview | The hero image. Use a **complete month** so the "period total" card reads properly and the daily chart has a full run of bars. |
| `budgets.png` | Budgets | Best with three budgets in different states — one on track, one ahead of pace, one over — so the colour semantics are visible. |
| `quick-add.png` | Capture panel | Press ⌥⌘Space. Capture just the small panel. |
| `insights.png` | Insights | With a local model running, after pressing *Summarise this period*. |
| `ask.png` | Ask | After a question, so the evidence chip above the answer is visible. |

## Capturing

`⌘⇧4` then **Space**, then click the window. macOS captures the window with its
shadow; hold **⌥** while clicking to drop the shadow, which looks cleaner
embedded in a README.

Save them here with exactly the filenames above and the README picks them up.

## Getting good-looking data

An empty database makes for a sad screenshot. To populate a few months of
plausible history, **back up your real database first**:

```bash
DB=~/Library/Containers/com.sepehr.spend/Data/Library/Application\ Support/com.sepehr.spend/spend.sqlite
cp "$DB" ~/Desktop/spend-real-backup.sqlite
```

Then use Settings → *Save a backup* before you start, restore it afterwards, and
you are back where you began.

## A word of caution

These images end up in a public repository. Check them before committing —
merchant names and amounts are your actual financial history. Screenshots taken
from seeded demo data are the safe option, and are what the current ones use.
