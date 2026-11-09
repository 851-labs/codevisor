import { createServer } from "node:net"

const lowestPort = 1_024
const highestPort = 65_535

export function parsePort(value: string | undefined, name: string): number | undefined {
  if (value === undefined) return undefined

  const parsed = Number(value)
  if (!isUserPort(parsed)) {
    throw new Error(
      `${name} must be an integer from ${lowestPort} through ${highestPort}; received ${value}`
    )
  }
  return parsed
}

export async function findAvailablePort(
  preferred: number,
  base: number,
  range: number
): Promise<number> {
  for (let offset = 0; offset < range; offset += 1) {
    const candidate = base + ((preferred - base + offset) % range)
    if (await isPortAvailable(candidate)) return candidate
  }
  throw new Error(
    `No available Codevisor development port was found in ${base}-${base + range - 1}`
  )
}

export function isPortAvailable(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const probe = createServer()
    probe.unref()
    probe.once("error", () => resolve(false))
    probe.listen(port, "0.0.0.0", () => probe.close(() => resolve(true)))
  })
}

function isUserPort(value: number): boolean {
  return Number.isInteger(value) && value >= lowestPort && value <= highestPort
}
