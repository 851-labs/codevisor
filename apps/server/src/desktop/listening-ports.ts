import { readFileSync } from "node:fs"

export interface KernelTable {
  readonly path: string
  readonly absentWithoutIPv6?: boolean
}

const listening = "0A"
const kernelTables: ReadonlyArray<KernelTable> = [
  { path: "/proc/net/tcp" },
  { path: "/proc/net/tcp6", absentWithoutIPv6: true }
]

export const somethingListensOn = (
  port: number,
  tables: ReadonlyArray<KernelTable> = kernelTables
): boolean => tables.some((table) => listeningPorts(tableText(table)).has(port))

export const listeningPorts = (procNetTcp: string): ReadonlySet<number> => {
  const ports = new Set<number>()
  for (const line of procNetTcp.split("\n").slice(1)) {
    const [, local, , state] = line.trim().split(/\s+/)
    if (state !== listening || local === undefined) continue

    ports.add(Number.parseInt(local.slice(local.lastIndexOf(":") + 1), 16))
  }
  return ports
}

const tableText = (table: KernelTable): string => {
  try {
    return readFileSync(table.path, "utf8")
  } catch (error) {
    if (table.absentWithoutIPv6 === true && isMissing(error)) return ""

    throw new Error(`Can't read ${table.path}, so the desktop's TCP port can't be checked`, {
      cause: error
    })
  }
}

const isMissing = (error: unknown): boolean =>
  error instanceof Error && "code" in error && error.code === "ENOENT"
