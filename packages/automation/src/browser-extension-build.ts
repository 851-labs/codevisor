import { createHash } from "node:crypto"
import { readdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { expectRecord, isPlainRecord } from "./unknown-values.js"

export interface ExtensionHello {
  readonly protocol: number
  readonly build: string | undefined
}

export interface BundledExtension {
  readonly protocol: number | undefined
  readonly build: string
}

export const bundledExtension = (source: string): BundledExtension => {
  const known = bundled.get(source)
  if (known !== undefined) return known

  const manifest = expectRecord(readJson(join(source, "manifest.json")), "Extension manifest")
  const described = {
    protocol: sourceProtocol(source),
    build: `${String(manifest.version)} (${sourceHash(source)})`
  }
  bundled.set(source, described)
  return described
}

export const stampExtensionBuild = (extension: string, source: string): void => {
  const manifestPath = join(extension, "manifest.json")
  const manifest = expectRecord(readJson(manifestPath), "Extension manifest")
  const stamped = { ...manifest, version_name: bundledExtension(source).build }
  writeFileSync(manifestPath, `${JSON.stringify(stamped, null, 2)}\n`, { mode: 0o600 })
}

export const readExtensionHello = (params: unknown): ExtensionHello | undefined => {
  if (!isPlainRecord(params) || typeof params.protocol !== "number") return undefined
  return {
    protocol: params.protocol,
    build: typeof params.build === "string" ? params.build : undefined
  }
}

export const outdatedExtensionNote = (
  hello: ExtensionHello | undefined,
  expected: BundledExtension
): string | undefined => {
  if (hello === undefined) return olderThanApp
  if (expected.protocol !== undefined && hello.protocol < expected.protocol) return olderThanApp
  if (hello.build !== undefined && hello.build !== expected.build) return staleCopy
  return undefined
}

export const describeExtensionError = (summary: string): string => {
  const unsupported = /^Unsupported browser command: (.+)$/.exec(summary)
  if (unsupported === null) return summary
  return `The Codevisor Chrome extension is out of date: it doesn't know ${unsupported[1]}. ${howToUpdate}`
}

const howToUpdate =
  "Update it at chrome://extensions (turn on Developer mode, then Update), or press its reload button there if it was loaded unpacked."
const olderThanApp = `The Codevisor Chrome extension is older than this app, so some browser actions may fail. ${howToUpdate}`
const staleCopy = `Chrome is running an unpacked copy of the Codevisor extension from a different version of this app, so some browser actions may fail. ${howToUpdate}`

const bundled = new Map<string, BundledExtension>()
const perInstallFiles = new Set(["relay-config.js"])
const hashedExtensions = /\.(js|json|html|css)$/

const readJson = (path: string): unknown => JSON.parse(readFileSync(path, "utf8"))

const sourceProtocol = (source: string): number | undefined => {
  const declared = /CODEVISOR_EXTENSION_PROTOCOL = (\d+)/.exec(
    readFileSync(join(source, "extension-build.js"), "utf8")
  )
  return declared === null ? undefined : Number(declared[1])
}

const sourceHash = (source: string): string => {
  const hash = createHash("sha256")
  const files = readdirSync(source)
    .filter((name) => hashedExtensions.test(name) && !perInstallFiles.has(name))
    .toSorted()
  for (const name of files) hash.update(name).update(readFileSync(join(source, name)))
  return hash.digest("hex").slice(0, 8)
}
