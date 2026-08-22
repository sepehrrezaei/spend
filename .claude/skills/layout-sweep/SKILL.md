---
name: layout-sweep
description: Check a changed Flutter screen across the widths and text scales this app actually runs at. Use when a widget under lib/features is added or modified, especially anything containing a Row.
source: earned — five overflows shipped because every widget test ran at 1280x900
confidence: high
---

# Layout sweep

## The widths, and why each

`test/widget/dashboard_layout_test.dart` holds the parameterised table. At minimum:

| Width | Why |
|---|---|
| 402 | iPhone portrait — where a 328pt and an 84pt overflow appeared |
| 834 | iPad portrait |
| 1280 | desktop, the default window |
| 1600 | wide desktop |

Plus **1.8 text scale**, which is what turns a fixed-height box into a clipped one.

## What has gone wrong here

- **A `Row` sized for a 1180pt window.** `Row` cannot wrap; `Wrap` can.
- **A nested `Row` inside a `Wrap`.** The outer wrap has room, the inner row does not, and
  it overflows anyway. Make items direct children.
- **A fixed `SizedBox(height:)` around scalable text.** Use a minimum height and let
  content size it.
- **An `AppBar` `bottom` whose height is computed separately from the layout inside it.**
  Two measurements that must agree, and did not, so the title clipped. Prefer putting the
  bar in the body where it can size itself.
- **A threshold chosen by eye.** Measure, then add headroom for the longest string the
  widget can render — "September 2026" is wider than the "August 2026" you tested with.

## Method

Add the changed screen to the parameterised table rather than writing a one-off test.

Assert with `tester.takeException()`: a `RenderFlex overflowed` is *reported* to the
framework rather than thrown, so it surfaces there and nowhere else.

Use `AppTheme.light()`, never the default `MaterialApp` theme — `useMaterial3` and
`VisualDensity.compact` change intrinsic control sizes, and a guard measured against a
theme the app never renders is measuring the wrong layout.

Seed data first. An empty period renders a placeholder instead of the charts, and the
test then passes while looking at nothing.
