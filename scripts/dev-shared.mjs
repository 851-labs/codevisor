// Helpers shared by the development runners (scripts/dev.mjs and
// scripts/dev-ios.mjs): port scanning, health probing, process exit
// bookkeeping, filesystem probes, and the worktree icon color derivation.
import { access, readdir } from "node:fs/promises"
import { createServer } from "node:net"
import { join } from "node:path"

export function colorFromHash(hash) {
  const hue = Number.parseInt(hash.slice(0, 8), 16) % 360
  const saturation = 0.68
  const lightness = 0.5
  const chroma = (1 - Math.abs(2 * lightness - 1)) * saturation
  const section = hue / 60
  const x = chroma * (1 - Math.abs((section % 2) - 1))
  const [red, green, blue] =
    section < 1
      ? [chroma, x, 0]
      : section < 2
        ? [x, chroma, 0]
        : section < 3
          ? [0, chroma, x]
          : section < 4
            ? [0, x, chroma]
            : section < 5
              ? [x, 0, chroma]
              : [chroma, 0, x]
  const match = lightness - chroma / 2
  const channels = [red + match, green + match, blue + match]
  const bytes = channels.map((channel) => Math.round(channel * 255))
  return {
    hex: `#${bytes.map((byte) => byte.toString(16).padStart(2, "0")).join("")}`,
    composer: `extended-srgb:${channels.map((channel) => channel.toFixed(5)).join(",")},1.00000`
  }
}

export function parsePort(value, name) {
  if (value === undefined) return undefined
  const parsed = Number(value)
  if (!Number.isInteger(parsed) || parsed < 1_024 || parsed > 65_535) {
    throw new Error(`${name} must be an integer from 1024 through 65535; received ${value}`)
  }
  return parsed
}

export async function findAvailablePort(preferred, base, range) {
  for (let offset = 0; offset < range; offset += 1) {
    const candidate = base + ((preferred - base + offset) % range)
    if (await isPortAvailable(candidate)) return candidate
  }
  throw new Error(
    `No available Codevisor development port was found in ${base}-${base + range - 1}`
  )
}

export function isPortAvailable(port) {
  return new Promise((resolve) => {
    const probe = createServer()
    probe.unref()
    probe.once("error", () => resolve(false))
    probe.listen(port, "0.0.0.0", () => probe.close(() => resolve(true)))
  })
}

export async function pathExists(path) {
  try {
    await access(path)
    return true
  } catch {
    return false
  }
}

export async function directoryIsEmpty(path) {
  try {
    return (await readdir(path)).length === 0
  } catch (error) {
    if (error?.code === "ENOENT") return true
    throw error
  }
}

export async function containsAnyPath(root, names) {
  return (await Promise.all(names.map((name) => pathExists(join(root, name))))).some(Boolean)
}

export async function waitForHealth(port, child, attempts = 120) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (child.exitCode !== null) throw new Error("Codevisor server exited before becoming healthy")
    try {
      const response = await fetch(`http://127.0.0.1:${port}/v1/health`)
      if (response.ok) return
    } catch {
      // The listener is still starting.
    }
    await delay(250)
  }
  throw new Error(`Timed out waiting for the Codevisor server on port ${port}`)
}

export function waitForExit(child) {
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode })
  }
  return new Promise((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }))
  })
}

export function describeExit({ code, signal }) {
  return signal === null ? `code ${code ?? 1}` : `signal ${signal}`
}

export function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}
