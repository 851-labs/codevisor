import { isRegistryImage } from "./oci-manifest.js"
import { SandboxProviderError, type ProvisionProgress } from "./provider.js"
import {
  assertDiskRoom,
  diskShortfall,
  type TartCommands,
  type TartHost,
  type TartSizing
} from "./tart-vm.js"

const pullTimeoutMs = 3 * 60 * 60 * 1000
const progressStepPercent = 5
const totalPattern = /^pulling disk \(([\d.]+) GB compressed\)/
const percentPattern = /^(\d+)%$/
const terminalEscape = new RegExp(`${String.fromCharCode(27)}\\[[0-9;?]*[A-Za-z]`, "g")

export const ensurePulled = async (
  host: TartHost,
  tart: TartCommands,
  image: string,
  sizing: TartSizing,
  progress: ProvisionProgress
): Promise<void> => {
  await assertDiskRoom(host, sizing)
  if (!isRegistryImage(image) || (await tart.cached(image))) return

  await assertRoomToPull(host, image, sizing)
  await pull(host, image, progress)
}

const assertRoomToPull = async (host: TartHost, image: string, sizing: TartSizing) => {
  const shortfall = await diskShortfall(host, sizing, await host.imageBytes(image))
  if (shortfall !== undefined) throw new SandboxProviderError("tart", shortfall)
}

const pull = async (host: TartHost, image: string, progress: ProvisionProgress) => {
  progress.log(`tart pull ${image}`)
  const output = pullOutput(progress.log)
  const result = await host.run(["pull", image], {
    timeoutMs: pullTimeoutMs,
    onOutput: (_stream, text) => output.write(text)
  })
  output.flush()
  if (result.exitCode === 0) return

  throw new SandboxProviderError(
    "tart",
    `tart pull ${image} failed (exit ${result.exitCode}): ${result.stderr.trim()}`
  )
}

const pullOutput = (log: (line: string) => void) => {
  let pending = ""
  let totalGB: number | undefined
  let shownPercent = -progressStepPercent
  const line = (raw: string): void => {
    const text = raw.trim()
    const total = totalPattern.exec(text)?.[1]
    if (total !== undefined) totalGB = Number(total)
    const percent = percentPattern.exec(text)?.[1]
    if (percent === undefined) {
      if (text !== "") log(text)
      return
    }
    const value = Number(percent)
    if (value < shownPercent + progressStepPercent && value < 100) return
    shownPercent = value
    log(downloadedLine(value, totalGB))
  }
  return {
    write: (text: string): void => {
      const lines = (pending + text.replace(terminalEscape, "")).split(/\r\n|\r|\n/)
      pending = lines.splice(-1).join("")
      for (const each of lines) line(each)
    },
    flush: (): void => {
      if (pending !== "") line(pending)
      pending = ""
    }
  }
}

const downloadedLine = (percent: number, totalGB: number | undefined): string => {
  if (totalGB === undefined) return `Downloaded ${percent}%`
  const done = ((totalGB * percent) / 100).toFixed(1)
  return `Downloaded ${done} of ${totalGB.toFixed(1)} GB (${percent}%)`
}
