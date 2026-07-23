#!/usr/bin/env node

import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  utimesSync,
  writeFileSync
} from "node:fs"
import { basename, dirname, join, relative, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const usage = () => {
  console.error("usage: scripts/release/build-browser-extension.mjs <version> [output-dir]")
  console.error()
  console.error("Builds a production Chrome Web Store ZIP and SHA-256 checksum under output-dir.")
}

const args = process.argv.slice(2)
if (args.includes("--help") || args.includes("-h")) {
  usage()
  process.exit(0)
}
if (args.length < 1 || args.length > 2) {
  usage()
  process.exit(1)
}

const version = args[0]
const versionParts = version.split(".")
if (
  !/^(0|[1-9]\d*)(\.(0|[1-9]\d*)){0,3}$/.test(version) ||
  versionParts.some((part) => Number(part) > 65_535) ||
  versionParts.every((part) => Number(part) === 0)
) {
  throw new Error(
    `Invalid Chrome extension version "${version}"; expected one to four dot-separated integers from 0 to 65535, not all zero`
  )
}

const scriptDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(scriptDir, "../..")
const sourceDir = join(repoRoot, "apps/server/resources/browser-extension")
const outputDir = resolve(args[1] ?? join(repoRoot, "dist/release"))
const workRoot = join(repoRoot, "dist/release/work")
const archiveName = `Codevisor-Chrome-${version}.zip`
const archivePath = join(outputDir, archiveName)
const checksumPath = `${archivePath}.sha256`
const productionRelay = "ws://127.0.0.1:49361/v1/browser-use/extension/socket"

if (!existsSync(sourceDir)) {
  throw new Error(`Browser extension source is missing: ${sourceDir}`)
}

const collectFiles = (directory) => {
  const files = []
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name)
    if (entry.isDirectory()) {
      files.push(...collectFiles(path))
    } else if (entry.isFile()) {
      files.push(path)
    } else {
      throw new Error(`Unsupported extension source entry: ${path}`)
    }
  }
  return files
}

mkdirSync(outputDir, { recursive: true })
mkdirSync(workRoot, { recursive: true })
const stageDir = mkdtempSync(join(workRoot, "browser-extension-"))

try {
  cpSync(sourceDir, stageDir, {
    recursive: true,
    filter: (source) => basename(source) !== ".DS_Store"
  })

  const manifestPath = join(stageDir, "manifest.json")
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"))
  if (manifest.manifest_version !== 3) {
    throw new Error("The production extension must use Manifest V3")
  }

  manifest.name = "Codevisor"
  manifest.version = version
  manifest.description = "Control Chrome with Codevisor."
  delete manifest.version_name
  // The Store owns the production item identity. The public key remains in
  // source only so an unpacked development installation can use the same ID.
  delete manifest.key
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`)

  writeFileSync(
    join(stageDir, "relay-config.js"),
    `globalThis.CODEVISOR_RELAY = ${JSON.stringify(productionRelay)}\n`
  )

  const requiredFiles = [
    "manifest.json",
    "background.js",
    "connect.html",
    "connect.js",
    "offscreen.html",
    "offscreen.js",
    "popup.css",
    "popup.html",
    "popup.js",
    "relay-config.js",
    "icons/16.png",
    "icons/32.png",
    "icons/128.png"
  ]
  for (const requiredFile of requiredFiles) {
    if (!existsSync(join(stageDir, requiredFile))) {
      throw new Error(`Required extension file is missing: ${requiredFile}`)
    }
  }

  const files = collectFiles(stageDir).sort((left, right) =>
    relative(stageDir, left).localeCompare(relative(stageDir, right))
  )
  for (const file of files.filter((path) => path.endsWith(".js"))) {
    execFileSync(process.execPath, ["--check", file], { stdio: "inherit" })
  }

  // ZIP stores DOS timestamps, whose minimum representable year is 1980.
  // Normalizing mtimes and entry ordering keeps the artifact reproducible.
  const fixedTimestamp = new Date("1980-01-01T00:00:00.000Z")
  for (const file of files) {
    utimesSync(file, fixedTimestamp, fixedTimestamp)
  }

  rmSync(archivePath, { force: true })
  rmSync(checksumPath, { force: true })
  const relativeFiles = files.map((file) => relative(stageDir, file))
  execFileSync("zip", ["-X", "-q", archivePath, ...relativeFiles], {
    cwd: stageDir,
    stdio: "inherit"
  })
  execFileSync("unzip", ["-tqq", archivePath], { stdio: "inherit" })

  const archive = readFileSync(archivePath)
  const checksum = createHash("sha256").update(archive).digest("hex")
  writeFileSync(checksumPath, `${checksum}  ${archiveName}\n`)

  if (statSync(archivePath).size === 0) {
    throw new Error(`Extension archive is empty: ${archivePath}`)
  }

  console.log(archivePath)
  console.log(checksumPath)
} finally {
  rmSync(stageDir, { recursive: true, force: true })
}
