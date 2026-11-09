import { spawn } from "node:child_process"
import { createHash, randomUUID } from "node:crypto"
import { lstat, readFile, readdir, rename, rm, utimes, writeFile } from "node:fs/promises"
import { basename, isAbsolute, join, relative, sep } from "node:path"

import { cloneTree, ensureStoreEntry, sameVolume, touchStoreEntry } from "./apfs-clone.ts"
import { describeDifference, listTree } from "./file-trees.ts"

export interface ResolvedArtifact {
  readonly path: string
  readonly entry: string
}

export interface SharedArtifacts {
  readonly resolved: boolean
  readonly shared: Array<string>
}

interface RecordedArtifact extends ResolvedArtifact {
  readonly identity: string
}

interface Ledger {
  readonly version: number
  readonly fingerprint: string
  readonly artifacts: Array<RecordedArtifact>
}

type Log = (message: string) => void

const ledgerFile = "codevisor-shared-artifacts.json"
const ledgerVersion = 1
const stagingPrefix = ".codevisor-clone-"

export async function prepareSwiftArtifacts(options: {
  readonly stateDirectory: string
  readonly store: string
  readonly inputs: ReadonlyArray<string>
  readonly resolve: () => Promise<void>
  readonly log?: Log
  readonly now?: number
}): Promise<SharedArtifacts> {
  const {
    stateDirectory,
    store,
    log = (message) => console.warn(message),
    now = Date.now()
  } = options
  const fingerprint = await fingerprintFiles(options.inputs)
  const ledger = await readLedger(stateDirectory)
  if (ledger?.fingerprint === fingerprint && (await artifactsUnchanged(ledger.artifacts))) {
    await Promise.all(
      ledger.artifacts.map((artifact) => touchStoreEntry(store, artifact.entry, now))
    )
    return { resolved: false, shared: [] }
  }

  await options.resolve()
  await removeAbandonedStaging(stateDirectory)
  const { shared, recorded } = await shareResolvedArtifacts(stateDirectory, store, now, log)
  await writeLedger(stateDirectory, {
    version: ledgerVersion,
    fingerprint,
    artifacts: recorded
  }).catch((error: unknown) =>
    log(`warning: could not record shared Swift artifacts: ${messageOf(error)}`)
  )
  return { resolved: true, shared }
}

export async function readResolvedArtifacts(
  stateDirectory: string
): Promise<Array<ResolvedArtifact>> {
  const state = await readFile(join(stateDirectory, "workspace-state.json"), "utf8").then(
    (text): unknown => JSON.parse(text),
    () => undefined
  )
  const artifacts = recordOf(recordOf(state).object).artifacts
  if (!Array.isArray(artifacts)) return []

  return artifacts.flatMap((artifact: unknown) => {
    const path = recordOf(artifact).path
    const checksum = recordOf(recordOf(artifact).source).checksum
    if (typeof path !== "string" || typeof checksum !== "string") return []
    if (!/^[0-9a-f]{16,}$/.test(checksum) || !isInside(stateDirectory, path)) return []

    return [{ path, entry: `${checksum}-${basename(path)}` }]
  })
}

export async function fingerprintFiles(paths: ReadonlyArray<string>): Promise<string> {
  const hash = createHash("sha256")
  for (const path of paths) {
    hash.update(path)
    hash.update("\0")
    hash.update(await readFile(path).catch(() => "missing"))
    hash.update("\0")
  }
  return hash.digest("hex")
}

export async function prepareSwiftPackage(options: {
  readonly repoRoot: string
  readonly packagePath: string
  readonly store: string
  readonly inputs?: ReadonlyArray<string>
  readonly log?: Log
}): Promise<SharedArtifacts> {
  const absolute = join(options.repoRoot, options.packagePath)
  return prepareSwiftArtifacts({
    stateDirectory: join(absolute, ".build"),
    store: options.store,
    inputs: [
      join(absolute, "Package.swift"),
      join(absolute, "Package.resolved"),
      join(options.repoRoot, "packages/swift/Package.swift"),
      join(options.repoRoot, "packages/swift/Package.resolved"),
      ...(options.inputs ?? [])
    ],
    resolve: () => run("swift", ["package", "resolve", "--package-path", absolute]),
    ...(options.log === undefined ? {} : { log: options.log })
  })
}

async function shareResolvedArtifacts(
  stateDirectory: string,
  store: string,
  now: number,
  log: Log
): Promise<{ shared: Array<string>; recorded: Array<RecordedArtifact> }> {
  const shared: Array<string> = []
  const recorded: Array<RecordedArtifact> = []
  for (const artifact of await readResolvedArtifacts(stateDirectory)) {
    try {
      if (await shareArtifact(artifact, stateDirectory, store, now)) shared.push(artifact.path)
    } catch (error) {
      log(`warning: could not share Swift artifact ${artifact.path}: ${messageOf(error)}`)
    }
    const identity = await directoryIdentity(artifact.path)
    if (identity !== undefined) recorded.push({ ...artifact, identity })
  }
  return { shared, recorded }
}

async function shareArtifact(
  artifact: ResolvedArtifact,
  stateDirectory: string,
  store: string,
  now: number
): Promise<boolean> {
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

  await replaceWithClones(stored, artifact.path, local, stateDirectory)
  await touchStoreEntry(store, artifact.entry, now)
  return true
}

async function replaceWithClones(
  stored: string,
  target: string,
  local: Awaited<ReturnType<typeof listTree>>,
  stateDirectory: string
): Promise<void> {
  const staging = join(stateDirectory, `${stagingPrefix}${randomUUID()}`)
  try {
    await cloneTree(stored, staging)
    for (const [path, file] of local) {
      if (file.type !== "file") continue

      const clone = join(staging, path)
      await utimes(clone, file.atime, file.mtime)
      await rename(clone, join(target, path))
    }
  } finally {
    await rm(staging, { recursive: true, force: true })
  }
}

async function artifactsUnchanged(artifacts: unknown): Promise<boolean> {
  if (!Array.isArray(artifacts)) return false

  for (const artifact of artifacts) {
    const { path, identity } = recordOf(artifact)
    if (typeof path !== "string" || (await directoryIdentity(path)) !== identity) return false
  }
  return true
}

async function directoryIdentity(path: string): Promise<string | undefined> {
  try {
    const info = await lstat(path, { bigint: true })
    return `${info.dev}:${info.ino}:${info.birthtimeNs}`
  } catch {
    return undefined
  }
}

async function readLedger(stateDirectory: string): Promise<Ledger | undefined> {
  try {
    const ledger: unknown = JSON.parse(await readFile(join(stateDirectory, ledgerFile), "utf8"))
    return isLedger(ledger) ? ledger : undefined
  } catch {
    return undefined
  }
}

async function writeLedger(stateDirectory: string, ledger: Ledger): Promise<void> {
  const path = join(stateDirectory, ledgerFile)
  const temporary = `${path}.${randomUUID()}`
  await writeFile(temporary, `${JSON.stringify(ledger, undefined, 2)}\n`)
  await rename(temporary, path)
}

async function removeAbandonedStaging(stateDirectory: string): Promise<void> {
  const names = await readdir(stateDirectory).catch(() => [])
  await Promise.all(
    names
      .filter((name) => name.startsWith(stagingPrefix))
      .map((name) => rm(join(stateDirectory, name), { recursive: true, force: true }))
  )
}

function isInside(directory: string, path: string): boolean {
  const offset = relative(directory, path)
  return offset !== "" && !isAbsolute(offset) && offset.split(sep)[0] !== ".."
}

function isLedger(value: unknown): value is Ledger {
  return recordOf(value).version === ledgerVersion
}

function recordOf(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object"
    ? Object.fromEntries(Object.entries(value))
    : {}
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function run(command: string, args: ReadonlyArray<string>): Promise<void> {
  const child = spawn(command, args, { stdio: "inherit" })
  return new Promise((resolve, reject) => {
    child.once("error", reject)
    child.once("exit", (code, signal) => {
      if (code === 0) resolve()
      else reject(new Error(`${command} ${args.join(" ")} failed (${signal ?? `code ${code}`})`))
    })
  })
}
