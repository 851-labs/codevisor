/// Tailnet peer enumeration for paired clients. The macOS app reads
/// `tailscale status --json` itself, but iOS is sandboxed and Tailscale
/// offers third-party apps no peer list — so the server (which can run the
/// CLI) reports its view of the tailnet, and clients probe the peers'
/// tokenless /v1/discovery manifests from their own side.
import { execFile } from "node:child_process"
import type { TailnetPeer } from "@codevisor/api"

/// The CLI is the one interface every install variant exposes consistently:
/// PATH covers Linux and open-source macOS installs, the app-bundle binary
/// covers the macOS GUI installs.
export const tailscaleBinaryCandidates = [
  "tailscale",
  "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
]

/// Decodes the JSON printed by `tailscale status --json`. Field names follow
/// Tailscale's own casing. Returns undefined for unparseable output and an
/// empty list when the backend isn't running.
export const parseTailnetPeers = (json: string): TailnetPeer[] | undefined => {
  interface Node {
    readonly HostName?: unknown
    readonly DNSName?: unknown
    readonly TailscaleIPs?: unknown
    readonly OS?: unknown
    readonly Online?: unknown
  }
  let status: { readonly BackendState?: unknown; readonly Peer?: Record<string, Node> }
  try {
    status = JSON.parse(json) as typeof status
  } catch {
    return undefined
  }
  if (typeof status !== "object" || status === null) return undefined
  if (status.BackendState !== undefined && status.BackendState !== "Running") return []
  const peers = Object.values(status.Peer ?? {}).flatMap((node): TailnetPeer[] => {
    if (typeof node.HostName !== "string" || node.HostName.length === 0) return []
    const dnsName = typeof node.DNSName === "string" ? node.DNSName.replace(/\.$/, "") : undefined
    const ips = Array.isArray(node.TailscaleIPs) ? node.TailscaleIPs : []
    const ip = ips.find((value): value is string => typeof value === "string")
    return [
      {
        hostName: node.HostName,
        ...(dnsName !== undefined && dnsName.length > 0 ? { dnsName } : {}),
        ...(ip === undefined ? {} : { ip }),
        ...(typeof node.OS === "string" ? { os: node.OS } : {}),
        online: node.Online === true
      }
    ]
  })
  return peers.sort((left, right) =>
    left.hostName.localeCompare(right.hostName, undefined, { sensitivity: "base" })
  )
}

/// Runs the first working Tailscale binary. Undefined when Tailscale is not
/// installed or the command fails — the route reports `available: false`.
export const readTailnetPeers = async (
  candidates: readonly string[] = tailscaleBinaryCandidates
): Promise<TailnetPeer[] | undefined> => {
  for (const binary of candidates) {
    const stdout = await new Promise<string | undefined>((resolve) => {
      execFile(
        binary,
        ["status", "--json"],
        { timeout: 5_000, maxBuffer: 8 * 1024 * 1024 },
        (error, out) => resolve(error === null ? out : undefined)
      )
    })
    if (stdout === undefined) continue
    const peers = parseTailnetPeers(stdout)
    if (peers !== undefined) return peers
  }
  return undefined
}
