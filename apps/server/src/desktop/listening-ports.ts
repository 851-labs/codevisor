import { readFileSync } from "node:fs"

const listening = "0A"
const kernelTables = ["/proc/net/tcp", "/proc/net/tcp6"]

export const somethingListensOn = (
  port: number,
  tables: ReadonlyArray<string> = kernelTables
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

const tableText = (table: string): string => {
  try {
    return readFileSync(table, "utf8")
  } catch {
    return ""
  }
}
