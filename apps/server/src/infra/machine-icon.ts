import { execFile } from "node:child_process"
import { readdir } from "node:fs/promises"
import { promisify } from "node:util"

import { field, stringField } from "../unknown-values.js"

export type RunCommand = (file: string, args: ReadonlyArray<string>) => Promise<string>

export const macIconForModel = (model: string): string => {
  if (model.startsWith("MacBook")) return "laptopcomputer"
  if (model === "Mac mini") return "macmini"
  if (model === "Mac Studio") return "macstudio"
  if (model === "Mac Pro") return "macpro.gen3"
  return "desktopcomputer"
}

const macModelName = (systemProfilerJson: string): string | undefined => {
  const overviews: unknown = field(JSON.parse(systemProfilerJson), "SPHardwareDataType")
  return Array.isArray(overviews) ? stringField(overviews[0], "machine_name") : undefined
}

export const guessMachineIcon = async (
  deps: {
    readonly platform?: NodeJS.Platform
    readonly run?: RunCommand
    readonly listDirectory?: (path: string) => Promise<ReadonlyArray<string>>
  } = {}
): Promise<string | undefined> => {
  /* v8 ignore start */
  const platform = deps.platform ?? process.platform
  const run =
    deps.run ??
    (async (file: string, args: ReadonlyArray<string>) =>
      (await promisify(execFile)(file, [...args], { timeout: 5_000 })).stdout)
  const listDirectory = deps.listDirectory ?? ((path: string) => readdir(path))
  /* v8 ignore stop */
  switch (platform) {
    case "darwin": {
      const model = await run("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"])
        .then(macModelName)
        .catch(() => undefined)
      return macIconForModel(model ?? "")
    }
    case "linux": {
      const supplies = await listDirectory("/sys/class/power_supply").catch(() => [])
      return supplies.some((entry) => entry.startsWith("BAT")) ? "laptopcomputer" : "server.rack"
    }
    case "win32":
      return "pc"
    default:
      return undefined
  }
}
