const listening = "0A"

export const listeningPorts = (procNetTcp: string): ReadonlySet<number> => {
  const ports = new Set<number>()
  for (const line of procNetTcp.split("\n").slice(1)) {
    const [, local, , state] = line.trim().split(/\s+/)
    if (state !== listening || local === undefined) continue

    ports.add(Number.parseInt(local.slice(local.lastIndexOf(":") + 1), 16))
  }
  return ports
}
