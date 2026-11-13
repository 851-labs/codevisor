import type { NetworkInterfaceInfo } from "node:os"

import { describe, expect, it } from "vitest"

import { localNetworkProbeTarget } from "./local-network-permission.js"

const ipv4 = (cidr: string, internal = false): NetworkInterfaceInfo => ({
  address: cidr.split("/")[0]!,
  netmask: "",
  family: "IPv4",
  mac: "00:00:00:00:00:00",
  internal,
  cidr
})

describe("local network probe target", () => {
  it.each([
    ["192.168.10.200/24", "192.168.10.201"],
    ["192.168.10.253/24", "192.168.10.252"],
    ["10.0.0.2/8", "10.0.0.3"],
    ["192.168.1.6/29", "192.168.1.5"]
  ])("picks a neighbor of %s that is not the network's first or last host", (cidr, target) => {
    expect(localNetworkProbeTarget({ en0: [ipv4(cidr)] })).toBe(target)
  })

  it("skips loopback, link-local, point-to-point and tiny subnets, and prefers en interfaces", () => {
    expect(
      localNetworkProbeTarget({
        lo0: [ipv4("127.0.0.1/8", true)],
        bridge100: [ipv4("192.168.64.1/24")],
        utun4: [ipv4("100.126.92.35/32")],
        en1: [ipv4("169.254.3.4/16"), ipv4("192.168.1.234/24")]
      })
    ).toBe("192.168.1.235")
    expect(localNetworkProbeTarget({ en0: [ipv4("192.168.1.1/30")] })).toBeUndefined()
  })
})
