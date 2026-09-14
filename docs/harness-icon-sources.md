# Harness icon sources — 2026-09-13

Twelve additional harnesses now have SVG assets in both native apps. Combined
with the existing 25, 37 of the 38 catalog entries have branded artwork.
Construct is the only remaining SF Symbol fallback.

The assets are self-contained vectors and use the existing native template
rendering, so the system supplies the foreground color in light and dark mode.
Each modified SVG includes a comment describing its preparation. No raster
tracing, embedded bitmaps, remote resources, or runtime fonts are required.

## Artwork and provenance

Website assets were retrieved on 2026-09-13. Repository links pin the inspected
revision. Source labels identify where artwork was published; website access
alone does not establish an open-source license or transfer trademark rights.
Vendor marks remain their respective owners' property.

| Harness       | Source                                                                                                                                                | Provenance                       | Native preparation                                                                                                                  |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Auggie CLI    | [SVG source](https://www.augmentcode.com/favicon.svg)                                                                                                 | Vendor website                   | Removed theme CSS; added the original 512 × 512 viewBox; template color.                                                            |
| Factory Droid | [SVG source](https://github.com/agentclientprotocol/registry/blob/408ececf2b8bde9451ef96f0c8c4d5e7e910825f/factory-droid/icon.svg)                    | ACP registry, Apache-2.0         | Registry mark matches the official factory.ai favicon; removed fixed dimensions.                                                    |
| Blackbox AI   | [SVG source](https://www.blackbox.ai/blackbox/blackbox-mark.svg)                                                                                      | Official press kit               | Added square canvas padding; artwork unchanged.                                                                                     |
| Autohand Code | [SVG source](https://github.com/agentclientprotocol/registry/blob/408ececf2b8bde9451ef96f0c8c4d5e7e910825f/autohand/icon.svg)                         | ACP registry, Apache-2.0         | Removed fixed dimensions.                                                                                                           |
| DimCode       | [SVG source](https://dimcode.dev)                                                                                                                     | Vendor website, first header SVG | Retained current header artwork and viewBox; removed web attributes.                                                                |
| Dirac         | [SVG source](https://github.com/dirac-run/dirac/blob/28e83cb8a66ceaacdd40900a44018f4904136221/assets/icons/dirac.svg)                                 | Upstream repository, Apache-2.0  | Outlined the original Georgia Italic delta at 16 pt with the original baseline and centering; underline and dot unchanged.          |
| Nova          | [SVG source](https://github.com/agentclientprotocol/registry/blob/408ececf2b8bde9451ef96f0c8c4d5e7e910825f/nova/icon.svg)                             | ACP registry, Apache-2.0         | Removed fixed dimensions. Compass Agentic Platform mark; unrelated to Amazon Nova.                                                  |
| siGit Code    | [SVG source](https://code.sigit.si/favicon.svg)                                                                                                       | Vendor Code website              | Removed background tile, fitted canvas, and applied template color. Replaces the registry wordmark with its stray background shape. |
| Harn          | [SVG source](https://harnlang.com)                                                                                                                    | Vendor website, first header SVG | Replaced gradient with template color; geometry unchanged.                                                                          |
| Kimchi        | [SVG source](https://kimchi.dev/__l5e/assets-v1/67e17204-ec8b-4ad1-90bf-585357b04ac8/kimchi-logo.svg)                                                 | Vendor website                   | Extracted the pepper path from the wordmark; omitted circle and lettering; fitted square canvas and applied template color.         |
| Stakpak       | [SVG source](https://github.com/agentclientprotocol/registry/blob/408ececf2b8bde9451ef96f0c8c4d5e7e910825f/stakpak/icon.svg)                          | ACP registry, Apache-2.0         | Removed fixed dimensions.                                                                                                           |
| VT Code       | [SVG source](https://github.com/vinhnx/VTCode/blob/18f7d26c76e28ab83e3de4bec4874f5fc9264190/extensions/vscode-extension/media/vtcode-activitybar.svg) | Upstream repository, Apache-2.0  | Used the dedicated monochrome VS Code activity-bar icon; removed fixed dimensions.                                                  |

## Construct

No published brand SVG was found in the [Construct repository](https://github.com/construct-worlds/construct/tree/cf75b7398c784566b7003d7f63253be1b88d9186),
its README links, or its daemon web UI. The repository tree contains no SVG,
PNG, ICO, or ICNS files at that revision. The inline web UI SVGs are generic
status/layout controls. Construct keeps its existing `building.2` fallback.
This records the search result, not a claim that artwork cannot exist elsewhere.

## Licenses and reproducibility

Both apps include `HarnessIcons-NOTICES.txt`, with these source references,
modification notes, and the complete upstream ACP registry, Dirac, and VTCode
license texts. The original Lobe icon notice remains separate.

The normalized SVG SHA-256 values below identify the exact bundled assets.
Both platforms use byte-identical SVGs and asset manifests.

| Catalog ID      | SHA-256                                                            |
| --------------- | ------------------------------------------------------------------ |
| `auggie`        | `2233bf93f41e9c74d8f9664c0322437bada688206e337cc272e881ce822fc18f` |
| `factory-droid` | `b0469de515ff49bf6f119cdf9b7f94a5d64f4866ef24c4c5ac1028a07d910c2b` |
| `blackbox`      | `008592d2530f0d06ad21ff87bbfd20b783178f347e83cd2dadb7e5b15edbaf74` |
| `autohand`      | `f40e627db31a43ac272c1cfbb230fbfb735128ab933163c8ceeb2308b1a182a7` |
| `dimcode`       | `ecf86e4bf4c918545fc81ca2670211ed6c6fc181c41e9b4b7afbe3e92bfcfa98` |
| `dirac`         | `e603bb4bbf1d6750de0095694955e7f797d1941cf97b9a9b8796278b6b8c9bc8` |
| `nova`          | `d3676f67c99d241368e053591808553482aa9d8b8354a608e285b3b0402576a3` |
| `sigit`         | `4582cf41d10210d06a9e7e949c5eae67959cbb9b557b998835b04d024838b886` |
| `harn`          | `33a15ff4ec98d06f8aa90adfbdb49976988341af3394df331157161a4eca4c45` |
| `kimchi`        | `5e1f678cc6596f35a73eb7f809d1af8bd63e1df8cd06a91cc7f4e09a73c97842` |
| `stakpak`       | `44bf44af396e1d2d75c87d4493d4b1ca172ffabc934401a2b4d991c6d96c0bb8` |
| `vtcode`        | `8836d39db8d2c65a5e80a0cbf672bbd6c7f455c464597f086583ee309176b8a3` |
