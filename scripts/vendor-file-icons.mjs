#!/usr/bin/env bun
// Regenerate the native catalog from the pinned reference; no extension runtime is shipped.
import { execFileSync } from "node:child_process"
import { copyFileSync, mkdirSync, rmSync, writeFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { extensions } from "../.repos/vscode-icons/src/iconsManifest/supportedExtensions.ts"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const upstream = join(root, ".repos/vscode-icons")
const resources = join(root, "packages/swift/CodevisorUI/Sources/CodevisorUI/Resources")
const catalog = join(resources, "FileIcons.xcassets")
const metadata = join(resources, "FileIcons")
const revision = execFileSync("git", ["rev-parse", "HEAD"], {
  cwd: upstream,
  encoding: "utf8"
}).trim()
const active = extensions.supported
  .filter((item) => !item.disabled && item.icon)
  .toSorted((a, b) => (a.icon < b.icon ? -1 : a.icon > b.icon ? 1 : 0))
const names = {}
const suffixes = {}
const languageNames = {}
const languageSuffixes = {}
const definitions = new Map()

// Match upstream's precedence: explicit associations override language defaults.
for (const item of active) {
  if (item.format !== 0) throw new Error(`Unsupported icon format: ${item.icon}`)
  definitions.set(item.icon, item)
  for (const language of item.languages ?? []) {
    for (const name of language.knownFilenames ?? []) languageNames[name.toLowerCase()] = item.icon
    for (const suffix of language.knownExtensions ?? [])
      languageSuffixes[suffix.toLowerCase()] = item.icon
  }
  const associations = [
    ...(item.extensions ?? []),
    ...(item.filenamesGlob ?? []).flatMap((name) =>
      (item.extensionsGlob ?? []).map((suffix) => `${name}.${suffix}`)
    )
  ]
  for (const association of associations) {
    if (item.filename) names[association.toLowerCase()] = item.icon
    else suffixes[association.replace(/^\./, "").toLowerCase()] = item.icon
  }
}

const fileNames = { ...languageNames, ...names }
const fileExtensions = { ...languageSuffixes, ...suffixes }
// Plain text uses the same native document symbol as unknown files.
delete fileExtensions.txt
const icons = [
  ...new Set([...Object.values(fileNames), ...Object.values(fileExtensions)])
].toSorted()
const sorted = (value) =>
  Object.fromEntries(Object.entries(value).toSorted(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))
const json = (value) => JSON.stringify(value, null, 2) + "\n"

rmSync(catalog, { recursive: true, force: true })
mkdirSync(catalog, { recursive: true })
mkdirSync(metadata, { recursive: true })
writeFileSync(join(catalog, "Contents.json"), json({ info: { author: "xcode", version: 1 } }))
for (const icon of icons) {
  const item = definitions.get(icon)
  const directory = join(catalog, `file_type_${icon}.imageset`)
  mkdirSync(directory)
  const filename = `file_type_${icon}.svg`
  copyFileSync(join(upstream, "icons", filename), join(directory, filename))
  const images = [{ filename, idiom: "universal" }]
  if (item.light) {
    const light = `file_type_light_${icon}.svg`
    copyFileSync(join(upstream, "icons", light), join(directory, light))
    images[0].appearances = [{ appearance: "luminosity", value: "dark" }]
    images.unshift({ filename: light, idiom: "universal" })
  }
  writeFileSync(
    join(directory, "Contents.json"),
    json({
      images,
      info: { author: "xcode", version: 1 },
      properties: {
        "preserves-vector-representation": true,
        // The monochrome Markdown mark needs native contrast in both appearances.
        "template-rendering-intent": icon === "markdown" ? "template" : "original"
      }
    })
  )
}
writeFileSync(
  join(metadata, "associations.json"),
  json({ revision, fileNames: sorted(fileNames), fileExtensions: sorted(fileExtensions) })
)
copyFileSync(join(upstream, "LICENSE"), join(metadata, "vscode-icons-MIT.txt"))
writeFileSync(
  join(metadata, "NOTICE.md"),
  `# File icons\n\nArtwork and associations from [vscode-icons](https://github.com/vscode-icons/vscode-icons), commit ${revision}.\n\nThe association source is MIT licensed; see vscode-icons-MIT.txt. Icon artwork is licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). Branded icons retain their respective owners’ copyright and trademark rights, as described by upstream.\n\nSVG artwork is copied without modification. Codevisor packages it into Apple asset catalogs with light/dark variants. The monochrome Markdown mark is rendered with the native secondary color for contrast. Plain text and unknown files use an SF Symbol. Regenerate with \`bun scripts/vendor-file-icons.mjs\`.\n`
)
process.stdout.write(
  `Vendored ${icons.length} icons, ${Object.keys(fileNames).length} filenames, and ${Object.keys(fileExtensions).length} extensions from ${revision}\n`
)
