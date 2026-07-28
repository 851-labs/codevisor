import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { parseTailnetPeers, readTailnetPeers } from "./tailnet.js"

const statusFixture = JSON.stringify({
  BackendState: "Running",
  Peer: {
    "key-1": {
      HostName: "studio",
      DNSName: "studio.tail1234.ts.net.",
      TailscaleIPs: ["100.64.0.2", "fd7a::2"],
      OS: "macOS",
      Online: true
    },
    "key-2": {
      HostName: "Phone",
      DNSName: "phone.tail1234.ts.net.",
      TailscaleIPs: ["100.64.0.3"],
      OS: "iOS",
      Online: false
    },
    "key-3": {
      // No host name — dropped.
      DNSName: "mystery.tail1234.ts.net."
    },
    // Minimal node: no DNS name, IPs, OS, or online flag.
    "key-4": { HostName: "bare" },
    // Degenerate values: a DNS name that strips to empty, non-array IPs.
    "key-5": { HostName: "dotty", DNSName: ".", TailscaleIPs: "nope", Online: true }
  }
})

describe("parseTailnetPeers", () => {
  it("decodes peers, strips trailing DNS dots, and sorts by host name", () => {
    const peers = parseTailnetPeers(statusFixture)
    expect(peers).toEqual([
      { hostName: "bare", online: false },
      { hostName: "dotty", online: true },
      {
        hostName: "Phone",
        dnsName: "phone.tail1234.ts.net",
        ip: "100.64.0.3",
        os: "iOS",
        online: false
      },
      {
        hostName: "studio",
        dnsName: "studio.tail1234.ts.net",
        ip: "100.64.0.2",
        os: "macOS",
        online: true
      }
    ])
  })

  it("returns an empty list when the backend is not running", () => {
    const json = JSON.stringify({ BackendState: "Stopped", Peer: { k: { HostName: "a" } } })
    expect(parseTailnetPeers(json)).toEqual([])
  })

  it("returns an empty list when there are no peers", () => {
    expect(parseTailnetPeers(JSON.stringify({ BackendState: "Running" }))).toEqual([])
  })

  it("returns undefined for unparseable output", () => {
    expect(parseTailnetPeers("not json")).toBeUndefined()
    expect(parseTailnetPeers("null")).toBeUndefined()
  })
})

describe("readTailnetPeers", () => {
  it("returns undefined when no candidate binary exists", async () => {
    const peers = await readTailnetPeers(["/nonexistent/tailscale-binary"])
    expect(peers).toBeUndefined()
  })

  it("skips binaries with unparseable output and reads peers from a working one", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-tailnet-"))
    const makeBinary = (name: string, stdout: string): string => {
      const path = join(directory, name)
      writeFileSync(path, `#!/bin/sh\nprintf %s '${stdout}'\n`)
      chmodSync(path, 0o755)
      return path
    }
    try {
      const bad = makeBinary("tailscale-bad", "not json")
      const good = makeBinary("tailscale-good", statusFixture)
      const peers = await readTailnetPeers([bad, good])
      expect(peers?.map((peer) => peer.hostName)).toEqual(["bare", "dotty", "Phone", "studio"])
    } finally {
      rmSync(directory, { recursive: true, force: true })
    }
  })
})
