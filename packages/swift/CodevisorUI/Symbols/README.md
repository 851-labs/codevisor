# Custom symbols

Source artwork for the custom SF Symbols in `Sources/CodevisorUI/Resources/Symbols.xcassets`. `codevisor-mark.svg` is the Codevisor mark, `harness-<id>.svg` is the logo for that harness, and the `git-*` glyphs are [Octicons](https://github.com/primer/octicons) (MIT) redrawn as centerlines: each ring, line and arrow sits on the middle of the Octicon's 1.5-unit stroke, so the script can stroke it at any weight. `git-branch-x` and `git-branch-dot` are our own: Octicons' `git-branch-check` with its check swapped for a round-capped ✕ or a dot, in the same place. Brand logos remain their owners' trademarks.

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

The script sizes each glyph from its convex-hull coverage so it sits on the text baseline at the same optical size as Apple's symbols. `overrides.json` pins `height` (in cap heights) for glyph families that share a grid.

Logos keep their own drawing at every weight, like Apple's `apple.logo`. Sources marked `lineArt` in `overrides.json` follow the text's weight instead: the script strokes their centerlines at SF Symbols' own stroke width for each of the nine weights and three image scales, measured from `circle`, and writes all 27 variants into the template. Line-art sources are `<path>` (absolute `M L H V C A Z`, circular arcs only) and `<circle>` elements with a stroke, round caps and joins; a shape that also has a fill, like a dot, is filled and stroked so it grows with the weight. Their `stroke-width` is only for previewing the source, set to about what Regular draws.

The bot mascot symbols (`mascot`, `mascot.fill`, `mascot.badge.plus`, `mascot.fill.badge.plus`) have no SVG source here. `scripts/generate-mascot-symbols.swift` draws them from the mascot's proportions into `Sources/CodevisorUI/Resources/MascotSymbols.xcassets` as Ultralight, Regular and Black masters with matching paths, so Xcode interpolates every weight. The outline is the fill's silhouette stroked inward, and its arch narrows at heavier weights so it keeps its shape. The badge copies the layers of Apple's `*.badge.plus` symbols: a clear-behind gap, a green disc in multicolor and a plus that's cut out in monochrome and white in multicolor. Regenerate with `swift scripts/generate-mascot-symbols.swift`.

Sources must be single-color shapes. SwiftDraw only outlines strokes on `<path>`, `<circle>`, and similar shapes with `fill="none"`; write lines as `<path>`, and flatten masks, gradients, and opacity. The script stops before touching the catalog if a source has a `<line>`, a `<polyline>`, or a stroked shape without `fill="none"`. It does not detect opacity.
