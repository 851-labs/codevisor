import { execFile } from "node:child_process"
import { mkdtemp, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { extname, isAbsolute, join } from "node:path"
import { promisify } from "node:util"

/// A macOS app's icon for the transcript rows of Computer Use workflows:
/// the `.app` the bridge reported when it is still the same bundle, else
/// wherever Spotlight finds that bundle ID. Its `.icns` becomes a PNG via
/// `sips`, which reads every size the format holds (sharp reads none).

/// Runs a command without a shell and resolves with its standard output.
export type RunCommand = (file: string, args: ReadonlyArray<string>) => Promise<string>

export type AppIconLoader = (
  bundleId: string,
  path: string | undefined
) => Promise<Uint8Array | undefined>

/// Reverse-DNS only, so the Spotlight query can't be anything else.
const BUNDLE_ID = /^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/

const ICON_PIXELS = "128"

export const makeAppIconLoader = (
  deps: {
    readonly run?: RunCommand
    readonly readFile?: (path: string) => Promise<Uint8Array>
  } = {}
): AppIconLoader => {
  /* v8 ignore start -- production defaults; tests inject both. */
  const run =
    deps.run ??
    (async (file: string, args: ReadonlyArray<string>) =>
      (await promisify(execFile)(file, [...args], { timeout: 5_000 })).stdout)
  const read = deps.readFile ?? (async (path: string) => new Uint8Array(await readFile(path)))
  /* v8 ignore stop */

  const plistValue = async (app: string, key: string): Promise<string | undefined> => {
    const plist = join(app, "Contents", "Info.plist")
    const value = await run("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", plist]).catch(
      () => ""
    )
    return value.trim() === "" ? undefined : value.trim()
  }

  const iconOf = async (app: string, bundleId: string): Promise<Uint8Array | undefined> => {
    // The path came from a transcript: only the bundle it names counts.
    if ((await plistValue(app, "CFBundleIdentifier")) !== bundleId) return undefined
    const name = await plistValue(app, "CFBundleIconFile")
    if (name === undefined) return undefined
    const icns = join(app, "Contents", "Resources", extname(name) === "" ? `${name}.icns` : name)
    const dir = await mkdtemp(join(tmpdir(), "codevisor-app-icon-"))
    const png = join(dir, "icon.png")
    try {
      await run("/usr/bin/sips", ["-s", "format", "png", "-Z", ICON_PIXELS, icns, "--out", png])
      return await read(png)
    } catch {
      return undefined
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  }

  return async (bundleId, path) => {
    if (!BUNDLE_ID.test(bundleId)) return undefined
    if (path !== undefined && isAbsolute(path) && path.endsWith(".app")) {
      const icon = await iconOf(path, bundleId)
      if (icon !== undefined) return icon
    }
    const found = await run("/usr/bin/mdfind", [
      `kMDItemCFBundleIdentifier == "${bundleId}"`
    ]).catch(() => "")
    for (const app of found.split("\n").map((line) => line.trim())) {
      if (!app.endsWith(".app") || app === path) continue
      const icon = await iconOf(app, bundleId)
      if (icon !== undefined) return icon
    }
    return undefined
  }
}
