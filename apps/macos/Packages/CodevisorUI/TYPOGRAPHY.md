# Typography

Grounded in the [Apple HIG Typography chapter](https://developer.apple.com/design/human-interface-guidelines/typography).
Enforced at commit time by `scripts/check-typography.sh`.

## Rules

1. **Never below the platform floor.** 11 pt on iOS/iPadOS, 10 pt on macOS —
   for text *and* SF Symbol glyphs. `Typography.minimumTextSize` resolves per
   platform.
2. **Prefer system text styles** (`.body`, `.headline`, `.caption`, …) for
   anything readable. They support Dynamic Type on iOS and keep hierarchy
   consistent on macOS. Handy macOS equivalences: `.largeTitle` = 26 pt,
   `.title3` = 15 pt, `.body` = 13 pt, `.callout` = 12 pt,
   `.subheadline` = 11 pt, `.caption2` = 10 pt (the floor — no headroom).
3. **No Light/Thin/Ultralight weights.**
4. **Recurring sizes are tokens**, not call-site literals:
   - `Typography.IconSize` — `.compact`/`.disclosure` (10), `.chrome` (12),
     `.toolbar` (13), `.hero` (34) for `Image(systemName:)` glyphs.
   - `Font.heroTitle` (36), `.stepTitle` (28), `.emptyStateTitle` (26),
     `.tabLabel(weight:)` (11.5) for display/chrome text.
5. **Fixed frames around text or glyphs must scale on iOS** — use
   `.scaledFrame(width:height:relativeTo:)` instead of `.frame` so containers
   grow with Dynamic Type (no-op on macOS).
6. **Tap targets ≥ 44×44 pt on iOS** — `.expandedHitTarget(base:)` grows the
   hit area without changing layout.
7. **UIKit monospaced fonts** must come from
   `UIFont.scaledMonospacedSystemFont(forTextStyle:)` (StreamMarkdown), never
   `monospacedSystemFont(ofSize: preferredFont(...).pointSize)` — the latter
   can't rescale in place when the content size category changes.
8. **Truncation must be recoverable.** If the full string isn't readable
   anywhere else, reflow at accessibility sizes:
   `lineLimit(dynamicTypeSize.isAccessibilitySize ? n : 1)`.
