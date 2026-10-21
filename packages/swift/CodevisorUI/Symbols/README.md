# Custom symbols

Source artwork for the custom SF Symbols in `Sources/CodevisorUI/Resources/Symbols.xcassets`. `harness-<id>.svg` is the logo for that harness; the `git-*` glyphs are [Octicons](https://github.com/primer/octicons) (MIT). Brand logos remain their owners' trademarks.

Regenerate the catalog after adding or editing a source:

```sh
brew install swiftdraw
swift scripts/generate-symbols.swift
```

The script sizes each glyph from its convex-hull coverage so it sits on the text baseline at the same optical size as Apple's symbols. `overrides.json` pins `height` (in cap heights) for glyph families that share a grid, and `outset` grows every edge by a fraction of the glyph height to bring outlined line art up to SF Symbols' regular stroke weight.

Sources must be single-color shapes. SwiftDraw only outlines strokes on `<path>`, `<circle>`, and similar shapes with `fill="none"`; write lines as `<path>`, and flatten masks, gradients, and opacity. The script stops before touching the catalog if a source has a `<line>`, a `<polyline>`, or a stroked shape without `fill="none"`. It does not detect opacity.
