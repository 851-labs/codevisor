// Vendors the curated Shiki preset themes into the HerdManTheming package
// resources and regenerates the theme manifest (which also indexes the Pierre
// themes already committed there). Output is committed; rerun when bumping the
// shiki dependency or changing the curated set:
//
//   bun apps/macos/scripts/vendor-shiki-themes.mjs
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..")

// The script lives outside the web app's dependency tree, so resolve the
// @shikijs/themes dist directory from the workspace store directly.
async function findShikiThemesDist() {
  const store = join(repoRoot, "node_modules/.bun")
  const entry = (await readdir(store)).find((name) => name.startsWith("@shikijs+themes@"))
  if (entry == null) throw new Error("@shikijs/themes not found — run bun install first")
  return join(store, entry, "node_modules/@shikijs/themes/dist")
}

const shikiDist = await findShikiThemesDist()
const themesDir = join(
  repoRoot,
  "apps/macos/Packages/HerdManTheming/Sources/HerdManTheming/Resources/Themes"
)

// Curated Shiki presets, a spread of well-known light and dark themes.
const SHIKI_THEMES = [
  "one-dark-pro",
  "dracula",
  "github-light",
  "github-dark",
  "catppuccin-latte",
  "catppuccin-mocha",
  "tokyo-night",
  "nord",
  "solarized-light",
  "solarized-dark",
  "gruvbox-dark-medium",
  "vitesse-light",
  "vitesse-dark",
  "rose-pine",
  "min-light",
  "vesper",
]

// The Pierre themes are committed directly (copied from
// references/pierre/packages/theme/themes); the manifest indexes them so the
// catalog reads one file for ordering and grouping.
const PIERRE_THEMES = [
  "pierre-light",
  "pierre-light-soft",
  "pierre-light-vibrant",
  "pierre-light-protanopia-deuteranopia",
  "pierre-light-tritanopia",
  "pierre-dark",
  "pierre-dark-soft",
  "pierre-dark-vibrant",
  "pierre-dark-protanopia-deuteranopia",
  "pierre-dark-tritanopia",
]

function titleCase(name) {
  return name
    .split("-")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ")
}

await mkdir(themesDir, { recursive: true })
const manifest = []

for (const name of PIERRE_THEMES) {
  const theme = JSON.parse(await readFile(join(themesDir, `${name}.json`), "utf8"))
  manifest.push({
    id: `pierre:${name}`,
    file: `${name}.json`,
    displayName: theme.displayName ?? titleCase(name),
    type: theme.type === "dark" ? "dark" : "light",
    group: "pierre",
  })
}

for (const name of SHIKI_THEMES) {
  const module = await import(pathToFileURL(join(shikiDist, `${name}.mjs`)).href)
  const theme = module.default ?? module
  await writeFile(join(themesDir, `${name}.json`), JSON.stringify(theme, null, 2) + "\n")
  manifest.push({
    id: `shiki:${name}`,
    file: `${name}.json`,
    displayName: theme.displayName ?? titleCase(name),
    type: theme.type === "dark" ? "dark" : "light",
    group: "shiki",
  })
}

await writeFile(join(themesDir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n")
console.log(`Wrote ${SHIKI_THEMES.length} shiki themes + manifest (${manifest.length} entries)`)
