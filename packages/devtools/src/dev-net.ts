import type { ChildProcess } from "node:child_process"
import { createHash } from "node:crypto"
import { copyFile, mkdir, readFile } from "node:fs/promises"
import { networkInterfaces } from "node:os"
import { dirname, join, relative } from "node:path"

import type { ContainerEngine } from "./container-engine.ts"
import type { DevContainerContext } from "./dev-containers.ts"
import { ensureDevCertificates } from "./dev-relay-certificates.ts"
import { type DevRelay, type DevRelayNet, startDevRelays, waitForDevRelays } from "./dev-relays.ts"
import { isPortAvailable } from "./ports.ts"

export interface DevNet extends DevRelayNet {
  readonly vmHost: string | undefined
}

export interface PreparedDevNet extends DevNet {
  readonly relayBinary: string
}

export interface NetArtifacts {
  readonly ensureNodeAddon: () => Promise<string>
  readonly ensureLinuxNodeAddon: (engine: ContainerEngine) => Promise<string>
  readonly ensureRelayBinary: () => Promise<string>
}

const relayCount = 2
const portsPerRelay = 5
const relayPortBase = 30_000
const relayPortSpan = 1000

export function devRelayHost(options: {
  readonly containerEngine?: ContainerEngine | undefined
  readonly containerHostAddress?: string | undefined
}): string {
  if (options.containerEngine === "apple" && options.containerHostAddress)
    return options.containerHostAddress
  if (options.containerEngine === "docker") return firstExternalIPv4() ?? "127.0.0.1"
  return "127.0.0.1"
}

export async function resolveDevNet(options: {
  readonly instanceHash: string
  readonly netRoot: string
  readonly relayHost: string
  readonly vmHost: string | undefined
}): Promise<DevNet> {
  const hosts = relayHosts(options.relayHost, options.vmHost)
  const slots = Math.floor(relayPortSpan / hosts.length)
  let slot = Number.parseInt(options.instanceHash.slice(0, 8), 16) % slots
  for (let attempt = 0; attempt < slots; attempt += 1, slot = (slot + 1) % slots) {
    const ports = portBlock(
      relayPortBase + slot * hosts.length * portsPerRelay,
      hosts.length * portsPerRelay
    )
    if (!(await allAvailable(ports))) continue

    return {
      relayHost: options.relayHost,
      vmHost: options.vmHost,
      relays: hosts.map((host, index) =>
        relayAt(host, ports.slice(index * portsPerRelay, (index + 1) * portsPerRelay))
      ),
      netRoot: options.netRoot,
      caFile: join(options.netRoot, "ca.pem"),
      authorizeToken: `dev-relay-${createHash("sha256").update(options.instanceHash).digest("hex").slice(0, 24)}`
    }
  }
  throw new Error("No free port range for the dev tunnel relays")
}

export function devRelayMap(net: DevRelayNet): Array<{ url: string; quicPort: number }> {
  return net.relays.map((relay) => ({ url: relay.url, quicPort: relay.ports.quic }))
}

export function devNetCloudVariables(net: DevRelayNet): Array<string> {
  return [
    "--var",
    `RELAY_MAP:${JSON.stringify(devRelayMap(net))}`,
    "--var",
    `RELAY_AUTHORIZE_TOKEN:${net.authorizeToken}`
  ]
}

export async function prepareDevNet(options: {
  readonly instanceHash: string
  readonly netRoot: string
  readonly repoRoot: string
  readonly containerContext: DevContainerContext | undefined
  readonly vmHost: string | undefined
  readonly artifacts: NetArtifacts
}): Promise<PreparedDevNet> {
  const { containerContext, artifacts } = options
  const relayHost = devRelayHost({
    containerEngine: containerContext?.engine,
    containerHostAddress: containerContext?.hostAddress
  })
  const net = await resolveDevNet({
    instanceHash: options.instanceHash,
    netRoot: options.netRoot,
    relayHost,
    vmHost: options.vmHost
  })
  await ensureDevCertificates(net)
  await artifacts.ensureNodeAddon()
  if (containerContext !== undefined) {
    const addon = await artifacts.ensureLinuxNodeAddon(containerContext.engine)
    const target = join(containerContext.appRoot, relative(options.repoRoot, addon))
    await mkdir(dirname(target), { recursive: true })
    await copyFile(addon, target)
  }
  return { ...net, relayBinary: await artifacts.ensureRelayBinary() }
}

export async function launchDevNet(options: {
  readonly net: PreparedDevNet
  readonly repoRoot: string
  readonly cloudPort: number
  readonly containerized: boolean
}): Promise<Array<ChildProcess>> {
  const processes = await startDevRelays({ ...options, relayBinary: options.net.relayBinary })
  if (await waitForDevRelays(options.net))
    console.log(`  relays:   ${options.net.relays.map((relay) => relay.url).join("  ")}`)
  else console.error("Dev tunnel relays did not become healthy; the tunnel runs direct-only.")
  return processes
}

export function devNetCaPem(net: DevRelayNet): Promise<string> {
  return readFile(net.caFile, "utf8")
}

export async function devNetEnvironment(
  net: DevRelayNet,
  { inline = false } = {}
): Promise<Record<string, string>> {
  const environment = { CODEVISOR_NET_CA_FILE: net.caFile }
  if (!inline) return environment

  return { ...environment, CODEVISOR_NET_CA_PEM: await devNetCaPem(net) }
}

function firstExternalIPv4(): string | undefined {
  for (const addresses of Object.values(networkInterfaces())) {
    const external = addresses?.find((address) => address.family === "IPv4" && !address.internal)
    if (external !== undefined) return external.address
  }
  return undefined
}

function relayHosts(
  relayHost: string,
  vmHost: string | undefined
): Array<{ name: string; host: string; bind?: string }> {
  const shared = Array.from({ length: relayCount }, (_, index) => ({
    name: `relay-${index + 1}`,
    host: relayHost
  }))
  if (vmHost === undefined) return shared

  return [...shared, { name: "relay-vm", host: vmHost, bind: "0.0.0.0" }]
}

function portBlock(base: number, count: number): Array<number> {
  return Array.from({ length: count }, (_, index) => base + index)
}

async function allAvailable(ports: ReadonlyArray<number>): Promise<boolean> {
  return (await Promise.all(ports.map((port) => isPortAvailable(port)))).every(Boolean)
}

function relayAt(
  host: { name: string; host: string; bind?: string },
  ports: ReadonlyArray<number>
): DevRelay {
  const [https = 0, quic = 0, router = 0, internal = 0, metrics = 0] = ports
  return {
    name: host.name,
    host: host.host,
    bind: host.bind,
    url: `https://${host.host}:${https}`,
    ports: { https, quic, router, internal, metrics }
  }
}
