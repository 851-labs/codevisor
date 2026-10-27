# Custom symbols

Source artwork for the custom SF Symbols in `Sources/CodevisorUI/Resources/Symbols.xcassets`. `codevisor-mark.svg` is the Codevisor mark, `harness-<id>.svg` is the logo for that harness, and the `git-*` glyphs are [Octicons](https://github.com/primer/octicons) (MIT). Brand logos remain their owners' trademarks.

`sandbox-vendor-<id>.svg` is the mark for that sandbox vendor, flattened to one color. Tart Orchard has no mark of its own and uses Tart's:

| Vendor | Source |
| --- | --- |
| Tart | Traced from the crust and apple-slice layers of the Tart app icon, [`Resources/UPW Tart.icon`](https://github.com/cirruslabs/tart/tree/main/Resources/UPW%20Tart.icon) in cirruslabs/tart; Tart publishes no single-color mark |
| E2B | [`e2b-symbol-black-s.svg`](https://e2b.dev/brand/e2b-symbol-black-s.svg) from [e2b.dev/brand](https://e2b.dev/brand) |
| Modal | [`favicon.svg`](https://modal.com/assets/favicon.svg) from [modal.com](https://modal.com), with its gradients filled solid |
| Vercel | [`vercel-symbol-black.svg`](https://vercel.com/geist/brands/assets/vercel-symbol-black.svg) from [vercel.com/geist/brands](https://vercel.com/geist/brands) |
| Daytona | [`src/assets/icons/logo-icon.svg`](https://github.com/daytonaio/docs/blob/main/src/assets/icons/logo-icon.svg) in daytonaio/docs |

Regenerate the catalog after adding or editing a source:

```sh
brew install swiftdraw
swift scripts/generate-symbols.swift
```

The script sizes each glyph from its convex-hull coverage so it sits on the text baseline at the same optical size as Apple's symbols. `overrides.json` pins `height` (in cap heights) for glyph families that share a grid, and `outset` grows every edge by a fraction of the glyph height to bring outlined line art up to SF Symbols' regular stroke weight.

Sources must be single-color shapes. SwiftDraw only outlines strokes on `<path>`, `<circle>`, and similar shapes with `fill="none"`; write lines as `<path>`, and flatten masks, gradients, and opacity. The script stops before touching the catalog if a source has a `<line>`, a `<polyline>`, or a stroked shape without `fill="none"`. It does not detect opacity.
