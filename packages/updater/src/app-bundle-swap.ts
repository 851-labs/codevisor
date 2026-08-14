import { createPublicKey, verify as cryptoVerify } from "node:crypto"
import { createWriteStream } from "node:fs"
import { mkdir, readFile, readdir, rename, rm, stat } from "node:fs/promises"
import { join } from "node:path"
import { Readable } from "node:stream"
import { pipeline } from "node:stream/promises"
import { execFile } from "node:child_process"
import { promisify } from "node:util"
import { parseAppcast, selectLatestAppcastItem, type AppcastItem } from "./appcast.js"

const execFileAsync = promisify(execFile)

/// Sparkle-style app bundle swap for the ChatGPT/Codex desktop app (whose
/// bundled `codex` CLI can't self-update). Downloads the official zip from
/// the app's own appcast, verifies it twice — the feed's EdDSA signature
/// against the installed app's SUPublicEDKey, then Apple codesign + Team ID
/// equality — and replaces the bundle with a staged atomic rename. Safe
/// while the app is running: the old bundle's inodes stay alive for the
/// running instance; it picks the new version up on relaunch.

export interface AppBundleSwapOps {
  /// Streams a URL to a file on disk.
  readonly download: (url: string, destination: string) => Promise<void>
  readonly execFile: (
    command: string,
    args: ReadonlyArray<string>
  ) => Promise<{ readonly stdout: string; readonly stderr: string }>
  readonly readFile: (path: string) => Promise<Buffer>
  readonly readdir: (path: string) => Promise<ReadonlyArray<string>>
  readonly rename: (from: string, to: string) => Promise<void>
  readonly remove: (path: string) => Promise<void>
  readonly mkdir: (path: string) => Promise<void>
  readonly fileSize: (path: string) => Promise<number>
}

/* v8 ignore start -- real network/filesystem/subprocess operations; the swap
   logic is fully covered through injected fakes, and these thin wrappers are
   exercised by the end-to-end app update flow. */
export const defaultAppBundleSwapOps: AppBundleSwapOps = {
  download: async (url, destination) => {
    const response = await fetch(url, { signal: AbortSignal.timeout(10 * 60_000) })
    if (!response.ok || response.body === null) {
      throw new Error(`Download failed: HTTP ${response.status}`)
    }
    await pipeline(
      Readable.fromWeb(response.body as import("node:stream/web").ReadableStream),
      createWriteStream(destination)
    )
  },
  execFile: async (command, args) => {
    const { stdout, stderr } = await execFileAsync(command, [...args], {
      maxBuffer: 4 * 1024 * 1024,
      timeout: 5 * 60_000
    })
    return { stderr, stdout }
  },
  fileSize: async (path) => (await stat(path)).size,
  mkdir: async (path) => {
    await mkdir(path, { recursive: true })
  },
  readFile: (path) => readFile(path),
  readdir: (path) => readdir(path),
  remove: async (path) => {
    await rm(path, { force: true, recursive: true })
  },
  rename: (from, to) => rename(from, to)
}
/* v8 ignore stop */

/// Wraps Sparkle's raw 32-byte Ed25519 public key (base64, from the app's
/// Info.plist SUPublicEDKey) in an SPKI DER header for node:crypto.
const ed25519PublicKey = (rawBase64: string) => {
  const raw = Buffer.from(rawBase64, "base64")
  if (raw.length !== 32) {
    throw new Error(`SUPublicEDKey is not a raw Ed25519 key (${raw.length} bytes)`)
  }
  const spkiPrefix = Buffer.from("302a300506032b6570032100", "hex")
  return createPublicKey({
    format: "der",
    key: Buffer.concat([spkiPrefix, raw]),
    type: "spki"
  })
}

export const verifyEdDSASignature = (
  data: Buffer,
  signatureBase64: string,
  publicKeyRawBase64: string
): boolean => {
  try {
    return cryptoVerify(
      null,
      data,
      ed25519PublicKey(publicKeyRawBase64),
      Buffer.from(signatureBase64, "base64")
    )
  } catch {
    return false
  }
}

const infoPlistValue = async (
  ops: AppBundleSwapOps,
  bundlePath: string,
  key: string
): Promise<string | undefined> => {
  try {
    const { stdout } = await ops.execFile("plutil", [
      "-extract",
      key,
      "raw",
      join(bundlePath, "Contents", "Info.plist")
    ])
    const value = stdout.trim()
    return value.length > 0 ? value : undefined
  } catch {
    return undefined
  }
}

/// "TeamIdentifier=2DC432GLL2" from `codesign -dv`'s stderr.
const teamIdentifier = async (ops: AppBundleSwapOps, bundlePath: string): Promise<string> => {
  const { stderr, stdout } = await ops.execFile("codesign", ["-dv", "--verbose=2", bundlePath])
  const match = /TeamIdentifier=([A-Z0-9]+)/.exec(`${stdout}\n${stderr}`)
  if (match?.[1] === undefined || match[1] === "not set") {
    throw new Error(`Couldn't read the Team ID of ${bundlePath}`)
  }
  return match[1]
}

export interface AppBundleSwapOptions {
  /// The installed bundle, e.g. /Applications/ChatGPT.app.
  readonly bundlePath: string
  /// Appcast XML content (already fetched by the update check layer).
  readonly appcastXml: string
  readonly ops?: AppBundleSwapOps
}

export interface AppBundleSwapResult {
  readonly installedVersion: string
}

/// Performs the verified swap. Throws (with the original bundle untouched or
/// restored) on any verification or filesystem failure.
export const applyAppBundleSwap = async (
  options: AppBundleSwapOptions
): Promise<AppBundleSwapResult> => {
  /* v8 ignore next -- tests always inject ops; the default performs real IO. */
  const ops = options.ops ?? defaultAppBundleSwapOps
  const { bundlePath } = options
  const item: AppcastItem | undefined = selectLatestAppcastItem(parseAppcast(options.appcastXml))
  if (item === undefined || item.shortVersion === undefined) {
    throw new Error("The update feed has no usable release")
  }
  if (item.edSignature === undefined) {
    throw new Error("The update feed entry is unsigned")
  }
  const publicKey = await infoPlistValue(ops, bundlePath, "SUPublicEDKey")
  if (publicKey === undefined) {
    throw new Error("The installed app has no Sparkle public key to verify against")
  }
  const installedTeam = await teamIdentifier(ops, bundlePath)

  // Staging lives next to the bundle so the final rename is same-volume
  // (atomic); everything under it is removed on any exit path.
  const staging = `${bundlePath}.codevisor-staging-${process.pid}`
  const previous = `${bundlePath}.codevisor-old`
  await ops.remove(staging)
  await ops.mkdir(staging)
  try {
    const zipPath = join(staging, "update.zip")
    await ops.download(item.url, zipPath)
    if (item.length !== undefined) {
      const size = await ops.fileSize(zipPath)
      if (size !== item.length) {
        throw new Error(`Download is incomplete (${size} of ${item.length} bytes)`)
      }
    }

    // 1/2: the feed's own signature, against the key the installed app ships.
    const signed = verifyEdDSASignature(await ops.readFile(zipPath), item.edSignature, publicKey)
    if (!signed) {
      throw new Error("The download failed Sparkle signature verification")
    }

    const extractDir = join(staging, "extracted")
    await ops.mkdir(extractDir)
    await ops.execFile("ditto", ["-x", "-k", zipPath, extractDir])
    const extractedApp = (await ops.readdir(extractDir)).find((name) => name.endsWith(".app"))
    if (extractedApp === undefined) {
      throw new Error("The downloaded archive contains no app bundle")
    }
    const newBundle = join(extractDir, extractedApp)

    // 2/2: Apple's chain — a valid signature from the same team as the
    // installed app.
    await ops.execFile("codesign", ["--verify", "--deep", "--strict", newBundle])
    const newTeam = await teamIdentifier(ops, newBundle)
    if (newTeam !== installedTeam) {
      throw new Error(`The download is signed by a different team (${newTeam} != ${installedTeam})`)
    }

    // Staged atomic swap with rollback: the old bundle survives (renamed
    // aside) until the new one is in place.
    await ops.remove(previous)
    await ops.rename(bundlePath, previous)
    try {
      await ops.rename(newBundle, bundlePath)
    } catch (cause) {
      /* v8 ignore next -- defensive: nothing can recover a failed rollback rename. */
      await ops.rename(previous, bundlePath).catch(() => undefined)
      throw cause
    }
    await ops.remove(previous)
    return { installedVersion: item.shortVersion }
  } finally {
    /* v8 ignore next -- defensive: staging cleanup failures leave only a temp directory. */
    await ops.remove(staging).catch(() => undefined)
  }
}
