// SwiftPM unpacks every binary artifact (WebRTC and Sentry, ~1.4 GB) into
// each directory it resolves packages into: both apps' SourcePackages and
// every SwiftPM package's .build, in every worktree. The bytes are identical
// (the zip's checksum is pinned), so after resolution each unpacked file is
// replaced by an APFS clone of one copy in a machine-wide store, keyed by
// that checksum. Builds see the same files; the disk holds them once.
//
// Replacement happens right after resolution and before the build so the
// build's own copies (Products/, which Xcode clones from these) share the
// same blocks and its dependency tracking never sees the files change.
import { spawn } from "node:child_process"
import { createHash, randomUUID } from "node:crypto"
import { lstat, readFile, readdir, readlink, rename, rm, utimes, writeFile } from "node:fs/promises"
import { basename, isAbsolute, join, relative, sep } from "node:path"

import { cloneTree, ensureStoreEntry, sameVolume, touchStoreEntry } from "./apfs-clone.mjs"

const LEDGER = "codevisor-shared-artifacts.json"
const LEDGER_VERSION = 1
const STAGING_PREFIX = ".codevisor-clone-"

/// Resolves packages into `stateDirectory` (SwiftPM's .build or Xcode's
/// SourcePackages) when their inputs changed, then shares the unpacked
/// binary artifacts. When nothing changed since the last run, this costs a
/// few stat calls and skips `resolve` entirely, so it adds nothing to boots.
///
/// `inputs` are the files that decide what gets resolved (manifests and
/// Package.resolved files). Sharing is best effort: a failure is logged and
/// the build continues with SwiftPM's own unshared files.
export async function prepareSwiftArtifacts({
  stateDirectory,
  store,
  inputs,
  resolve,
  log = (message) => console.warn(message),
  now = Date.now()
}) {
  const fingerprint = await fingerprintFiles(inputs)
  const ledger = await readLedger(stateDirectory)
  if (ledger?.fingerprint === fingerprint && (await artifactsUnchanged(ledger.artifacts))) {
    await Promise.all(
      ledger.artifacts.map((artifact) => touchStoreEntry(store, artifact.entry, now))
    )
    return { resolved: false, shared: [] }
  }
  await resolve()
  await removeAbandonedStaging(stateDirectory)
  const shared = []
  const recorded = []
  for (const artifact of await readResolvedArtifacts(stateDirectory)) {
    try {
      if (await shareArtifact(artifact, stateDirectory, store, now)) shared.push(artifact.path)
    } catch (error) {
      log(`warning: could not share Swift artifact ${artifact.path}: ${error.message}`)
    }
    const identity = await directoryIdentity(artifact.path)
    if (identity !== undefined) recorded.push({ ...artifact, identity })
  }
  try {
    await writeLedger(stateDirectory, { version: LEDGER_VERSION, fingerprint, artifacts: recorded })
  } catch (error) {
    // Without a ledger the next run resolves again; the build is unaffected.
    log(`warning: could not record shared Swift artifacts: ${error.message}`)
  }
  return { resolved: true, shared }
}

/// The checksum-pinned (downloaded) artifacts SwiftPM recorded as unpacked
/// under `stateDirectory`. Local artifacts (CodevisorNetFFI) already live in
/// a shared cache and are not listed with a checksum.
export async function readResolvedArtifacts(stateDirectory) {
  let state
  try {
    state = JSON.parse(await readFile(join(stateDirectory, "workspace-state.json"), "utf8"))
  } catch {
    return []
  }
  const artifacts = state?.object?.artifacts
  if (!Array.isArray(artifacts)) return []
  return artifacts
    .filter(
      (artifact) =>
        typeof artifact?.path === "string" &&
        typeof artifact?.source?.checksum === "string" &&
        /^[0-9a-f]{16,}$/.test(artifact.source.checksum) &&
        isInside(stateDirectory, artifact.path)
    )
    .map((artifact) => ({
      path: artifact.path,
      entry: `${artifact.source.checksum}-${basename(artifact.path)}`
    }))
}

/// Replaces every file of one unpacked artifact with a clone of the stored
/// copy. Each file is swapped by an atomic rename, so a concurrent reader
/// sees either the old file or the identical clone, never a missing one.
async function shareArtifact(artifact, stateDirectory, store, now) {
  // APFS clones (cp -c) are macOS-only; elsewhere SwiftPM's files stay as-is.
  if (process.platform !== "darwin") return false
  const name = basename(artifact.path)
  const entry = await ensureStoreEntry(
    store,
    artifact.entry,
    (staging) => cloneTree(artifact.path, join(staging, name)),
    now
  )
  if (!(await sameVolume(entry, artifact.path))) return false
  const stored = join(entry, name)
  const [local, reference] = await Promise.all([listTree(artifact.path), listTree(stored)])
  const difference = describeDifference(local, reference)
  if (difference !== undefined) throw new Error(`differs from ${stored} (${difference})`)

  const staging = join(stateDirectory, `${STAGING_PREFIX}${randomUUID()}`)
  try {
    await cloneTree(stored, staging)
    for (const [path, file] of local) {
      if (file.type !== "file") continue
      const clone = join(staging, path)
      // Keep the unpacked file's timestamps so build systems that compare
      // them see nothing new.
      await utimes(clone, file.atime, file.mtime)
      await rename(clone, join(artifact.path, path))
    }
  } finally {
    await rm(staging, { recursive: true, force: true })
  }
  await touchStoreEntry(store, artifact.entry, now)
  return true
}

/// Relative path → { type, size, mode, target } for every entry in a tree.
export async function listTree(root) {
  const entries = new Map()
  const visit = async (directory) => {
    for (const child of await readdir(directory, { withFileTypes: true })) {
      const path = join(directory, child.name)
      const key = relative(root, path)
      if (child.isDirectory()) {
        entries.set(key, { type: "directory" })
        await visit(path)
      } else if (child.isSymbolicLink()) {
        entries.set(key, { type: "symlink", target: await readlink(path) })
      } else if (child.isFile()) {
        const info = await lstat(path)
        entries.set(key, {
          type: "file",
          size: info.size,
          mode: info.mode & 0o7777,
          atime: info.atime,
          mtime: info.mtime
        })
      }
    }
  }
  await visit(root)
  return entries
}

/// Why two listed trees are not interchangeable, or undefined when every
/// path has the same kind, size, permissions, and link target.
export function describeDifference(local, reference) {
  if (local.size !== reference.size) return `${local.size} entries, store has ${reference.size}`
  for (const [path, file] of local) {
    const other = reference.get(path)
    if (other === undefined) return `${path} missing from store`
    if (
      other.type !== file.type ||
      other.size !== file.size ||
      other.mode !== file.mode ||
      other.target !== file.target
    ) {
      return `${path} changed`
    }
  }
  return undefined
}

async function artifactsUnchanged(artifacts) {
  if (!Array.isArray(artifacts)) return false
  for (const artifact of artifacts) {
    if ((await directoryIdentity(artifact.path)) !== artifact.identity) return false
  }
  return true
}

/// SwiftPM unpacks into a fresh directory whenever it (re)extracts an
/// artifact, so the directory's identity tells whether the files are still
/// the ones that were shared. Sharing swaps files, never the directory.
/// The inode alone is not enough: Linux file systems reuse a freed inode
/// number for the next directory created, so include its creation time.
async function directoryIdentity(path) {
  try {
    const info = await lstat(path, { bigint: true })
    return `${info.dev}:${info.ino}:${info.birthtimeNs}`
  } catch {
    return undefined
  }
}

export async function fingerprintFiles(paths) {
  const hash = createHash("sha256")
  for (const path of paths) {
    hash.update(path)
    hash.update("\0")
    try {
      hash.update(await readFile(path))
    } catch {
      hash.update("missing")
    }
    hash.update("\0")
  }
  return hash.digest("hex")
}

async function readLedger(stateDirectory) {
  try {
    const ledger = JSON.parse(await readFile(join(stateDirectory, LEDGER), "utf8"))
    return ledger?.version === LEDGER_VERSION ? ledger : undefined
  } catch {
    return undefined
  }
}

async function writeLedger(stateDirectory, ledger) {
  const path = join(stateDirectory, LEDGER)
  const temporary = `${path}.${randomUUID()}`
  await writeFile(temporary, `${JSON.stringify(ledger, undefined, 2)}\n`)
  await rename(temporary, path)
}

function isInside(directory, path) {
  const offset = relative(directory, path)
  return offset !== "" && !isAbsolute(offset) && offset.split(sep)[0] !== ".."
}

/// Staging trees left by a process that died mid-swap.
async function removeAbandonedStaging(stateDirectory) {
  const names = await readdir(stateDirectory).catch(() => [])
  await Promise.all(
    names
      .filter((name) => name.startsWith(STAGING_PREFIX))
      .map((name) => rm(join(stateDirectory, name), { recursive: true, force: true }))
  )
}

/// Prepares a SwiftPM package for `swift build`/`swift test`: resolves it
/// into its .build when its manifests changed and shares the artifacts.
export async function prepareSwiftPackage({ repoRoot, packagePath, store, inputs = [], log }) {
  const absolute = join(repoRoot, packagePath)
  return prepareSwiftArtifacts({
    stateDirectory: join(absolute, ".build"),
    store,
    inputs: [
      join(absolute, "Package.swift"),
      join(absolute, "Package.resolved"),
      // The local CodevisorKit package declares the Sentry binary target.
      join(repoRoot, "packages/swift/Package.swift"),
      join(repoRoot, "packages/swift/Package.resolved"),
      ...inputs
    ],
    resolve: () => run("swift", ["package", "resolve", "--package-path", absolute]),
    log
  })
}

function run(command, arguments_) {
  const child = spawn(command, arguments_, { stdio: "inherit" })
  return new Promise((resolve, reject) => {
    child.once("error", reject)
    child.once("exit", (code, signal) => {
      if (code === 0) resolve()
      else
        reject(new Error(`${command} ${arguments_.join(" ")} failed (${signal ?? `code ${code}`})`))
    })
  })
}
