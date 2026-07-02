// Bundles the Shiki highlighter (highlighter-entry.mjs) into a single IIFE
// the macOS app evaluates in JavaScriptCore. Output is committed; rerun when
// bumping shiki or changing the grammar set:
//
//   bun apps/macos/scripts/build-highlighter.mjs
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const scriptsDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(scriptsDir, "../../..")
const outfile = join(
  repoRoot,
  "apps/macos/Packages/CodeHighlighter/Sources/CodeHighlighter/Resources/highlighter.js"
)

const result = await Bun.build({
  entrypoints: [join(scriptsDir, "highlighter-entry.mjs")],
  outdir: dirname(outfile),
  naming: "highlighter.js",
  format: "iife",
  target: "browser",
  minify: true,
})

if (!result.success) {
  for (const log of result.logs) console.error(log)
  process.exit(1)
}
const size = Bun.file(outfile).size
console.log(`Wrote ${outfile} (${(size / 1024 / 1024).toFixed(1)} MB)`)
