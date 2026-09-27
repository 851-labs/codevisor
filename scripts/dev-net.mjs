// Local tunnel relays for `bun run dev` (docs/plans/codevisor-tunnel.md).
//
// Two iroh-relay processes run from the same pinned binary as production
// (scripts/net-build.lock.json), configured by the same
// infra/relays/render-config.sh, each behind the same port-80 router. The
// only differences from production are configuration: per-worktree ports,
// a per-worktree dev CA instead of Let's Encrypt, and relay access checked
// against the local wrangler instead of cloud.codevisor.dev.
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { access, copyFile, mkdir, readFile, writeFile } from "node:fs/promises"
import { request } from "node:https"
import { networkInterfaces } from "node:os"
import { dirname, join, relative } from "node:path"
import { fileURLToPath } from "node:url"

import { delay, isPortAvailable } from "./dev-shared.mjs"

const repoRootOf = () => join(dirname(fileURLToPath(import.meta.url)), "..")

const RELAYS = 2
/// Per relay: https, QAD (udp), router http, relay-internal http, metrics.
const PORTS_PER_RELAY = 5

const exists = (path) =>
  access(path).then(
    () => true,
    () => false
  )

/// The host address every dev device can reach the relays at. Apple
/// `container` machines reach the host at the vmnet gateway, which is also
/// one of the host's own addresses; Docker containers can't reach the host's
/// loopback, so they get the host's LAN address. Same-host mode: loopback.
export function devRelayHost({ containerEngine, containerHostAddress }) {
  if (containerEngine === "apple" && containerHostAddress) return containerHostAddress
  if (containerEngine === "docker") {
    for (const addresses of Object.values(networkInterfaces())) {
      for (const address of addresses ?? []) {
        if (address.family === "IPv4" && !address.internal) return address.address
      }
    }
  }
  return "127.0.0.1"
}

/// Stable per-worktree ports (30000–39999), scanning forward when taken.
export async function resolveDevNet({ instanceHash, netRoot, relayHost }) {
  const slots = 1000 / RELAYS
  let slot = Number.parseInt(instanceHash.slice(0, 8), 16) % slots
  for (let attempt = 0; attempt < slots; attempt += 1, slot = (slot + 1) % slots) {
    const base = 30_000 + slot * RELAYS * PORTS_PER_RELAY
    const ports = Array.from({ length: RELAYS * PORTS_PER_RELAY }, (_, index) => base + index)
    if ((await Promise.all(ports.map((port) => isPortAvailable(port)))).every(Boolean)) {
      const relays = Array.from({ length: RELAYS }, (_, index) => {
        const [https, quic, router, internal, metrics] = ports.slice(
          index * PORTS_PER_RELAY,
          (index + 1) * PORTS_PER_RELAY
        )
        return {
          name: `relay-${index + 1}`,
          url: `https://${relayHost}:${https}`,
          ports: { https, quic, router, internal, metrics }
        }
      })
      return {
        relayHost,
        relays,
        netRoot,
        caFile: join(netRoot, "ca.pem"),
        authorizeToken: `dev-relay-${createHash("sha256").update(instanceHash).digest("hex").slice(0, 24)}`
      }
    }
  }
  throw new Error("No free port range for the dev tunnel relays")
}

/// The relay map the local cloud hands to devices (RELAY_MAP).
export const devRelayMap = (net) =>
  net.relays.map((relay) => ({ url: relay.url, quicPort: relay.ports.quic }))

export const devNetCloudVariables = (net) => [
  "--var",
  `RELAY_MAP:${JSON.stringify(devRelayMap(net))}`,
  "--var",
  `RELAY_AUTHORIZE_TOKEN:${net.authorizeToken}`
]

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "ignore", "inherit"], ...options })
    child.on("error", reject)
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`${command} ${args.join(" ")} exited ${code}`))
    )
  })
}

/// A per-worktree CA plus one relay certificate for every name devices use.
/// Regenerated only when the name set changes.
export async function ensureDevCertificates(net) {
  const names = [...new Set(["localhost", "127.0.0.1", "::1", net.relayHost])]
  const dir = net.netRoot
  await mkdir(dir, { recursive: true })
  const namesFile = join(dir, "cert-names.json")
  const current = await readFile(namesFile, "utf8").catch(() => "")
  if (current === JSON.stringify(names) && (await exists(join(dir, "relay.key")))) return
  const sans = names
    .map((name) => (/^[0-9.:]+$/.test(name) ? `IP:${name}` : `DNS:${name}`))
    .join(",")
  await writeFile(
    join(dir, "relay.ext"),
    `basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\n` +
      `extendedKeyUsage=serverAuth\nsubjectAltName=${sans}\n`
  )
  await writeFile(
    join(dir, "ca.ext"),
    "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n"
  )
  const openssl = (...args) => run("openssl", args, { cwd: dir })
  await openssl("ecparam", "-genkey", "-name", "prime256v1", "-noout", "-out", "ca.sec1.key")
  await openssl("pkcs8", "-topk8", "-nocrypt", "-in", "ca.sec1.key", "-out", "ca.key")
  await openssl(
    "req",
    "-new",
    "-key",
    "ca.key",
    "-subj",
    "/CN=Codevisor Dev Relay CA",
    "-out",
    "ca.csr"
  )
  await openssl(
    "x509",
    "-req",
    "-in",
    "ca.csr",
    "-signkey",
    "ca.key",
    "-days",
    "825",
    "-extfile",
    "ca.ext",
    "-out",
    "ca.pem"
  )
  await openssl("ecparam", "-genkey", "-name", "prime256v1", "-noout", "-out", "relay.sec1.key")
  await openssl("pkcs8", "-topk8", "-nocrypt", "-in", "relay.sec1.key", "-out", "relay.key")
  await openssl(
    "req",
    "-new",
    "-key",
    "relay.key",
    "-subj",
    "/CN=codevisor-dev-relay",
    "-out",
    "relay.csr"
  )
  await openssl(
    "x509",
    "-req",
    "-in",
    "relay.csr",
    "-CA",
    "ca.pem",
    "-CAkey",
    "ca.key",
    "-CAcreateserial",
    "-days",
    "825",
    "-extfile",
    "relay.ext",
    "-out",
    "relay.pem"
  )
  await writeFile(namesFile, JSON.stringify(names))
}

/// Starts both relays (router + iroh-relay each). Returns the processes.
export async function startDevRelays({ net, repoRoot, relayBinary, cloudPort, containerized }) {
  const bind = containerized ? "0.0.0.0" : "127.0.0.1"
  const processes = []
  for (const relay of net.relays) {
    const dir = join(net.netRoot, relay.name)
    await mkdir(join(dir, "acme-webroot"), { recursive: true })
    const relayEnvironment = {
      ...process.env,
      RELAY_HOSTNAME: net.relayHost,
      RELAY_CERT_PATH: join(net.netRoot, "relay.pem"),
      RELAY_KEY_PATH: join(net.netRoot, "relay.key"),
      RELAY_AUTHORIZE_URL: `http://127.0.0.1:${cloudPort}/api/relay/authorize`,
      RELAY_AUTHORIZE_TOKEN: net.authorizeToken,
      RELAY_HTTP_BIND_ADDR: `127.0.0.1:${relay.ports.internal}`,
      RELAY_HTTPS_BIND_ADDR: `${bind}:${relay.ports.https}`,
      RELAY_QUIC_BIND_ADDR: `${bind}:${relay.ports.quic}`,
      RELAY_METRICS_BIND_ADDR: `127.0.0.1:${relay.ports.metrics}`,
      RUST_LOG: process.env.CODEVISOR_DEV_RELAY_LOG ?? "warn"
    }
    const config = await new Promise((resolve, reject) => {
      const child = spawn("sh", [join(repoRoot, "infra/relays/render-config.sh")], {
        env: relayEnvironment,
        stdio: ["ignore", "pipe", "inherit"]
      })
      let output = ""
      child.stdout.on("data", (chunk) => {
        output += chunk
      })
      child.on("error", reject)
      child.on("exit", (code) =>
        code === 0 ? resolve(output) : reject(new Error(`render-config.sh exited ${code}`))
      )
    })
    const configPath = join(dir, "iroh-relay.toml")
    await writeFile(configPath, config)
    processes.push(
      spawn(relayBinary, ["--config-path", configPath], {
        env: relayEnvironment,
        stdio: ["ignore", "inherit", "inherit"]
      }),
      spawn("python3", [join(repoRoot, "infra/relays/port80-router.py")], {
        env: {
          ...relayEnvironment,
          ROUTER_HOST: bind,
          ROUTER_PORT: String(relay.ports.router),
          ACME_WEBROOT: join(dir, "acme-webroot")
        },
        stdio: ["ignore", "inherit", "inherit"]
      })
    )
  }
  return processes
}

const healthy = (url, ca) =>
  new Promise((resolve) => {
    const req = request(`${url}/healthz`, { ca, timeout: 1000 }, (response) => {
      response.resume()
      resolve(response.statusCode === 200)
    })
    req.on("error", () => resolve(false))
    req.on("timeout", () => req.destroy())
    req.end()
  })

const routerHealthy = (relay) =>
  fetch(`http://127.0.0.1:${relay.ports.router}/generate_204`).then(
    (response) => response.status === 204,
    () => false
  )

/// Waits (bounded) until every relay answers /healthz over dev-CA TLS and its
/// port-80 router forwards captive-portal probes.
export async function waitForDevRelays(net) {
  const ca = await readFile(net.caFile)
  for (let attempt = 0; attempt < 80; attempt += 1) {
    const results = await Promise.all(
      net.relays.flatMap((relay) => [healthy(relay.url, ca), routerHealthy(relay)])
    )
    if (results.every(Boolean)) return true
    await delay(250)
  }
  return false
}

/// Everything before launch: ports, dev CA, the pinned relay binary, and (for
/// containerized dev remotes) the Linux tunnel addon.
export async function prepareDevNet({ instanceHash, netRoot, containerContext }) {
  const { ensureLinuxNodeAddon, ensureNodeAddon, ensureRelayBinary } =
    await import("./net-artifact.mjs")
  const relayHost = devRelayHost({
    containerEngine: containerContext?.engine,
    containerHostAddress: containerContext?.hostAddress
  })
  const net = await resolveDevNet({ instanceHash, netRoot, relayHost })
  await ensureDevCertificates(net)
  await ensureNodeAddon()
  if (containerContext !== undefined) {
    // The container workspace was synced before this build, so install the
    // Linux addon into the synced copy too (where the containers load it).
    const addon = await ensureLinuxNodeAddon(containerContext.engine)
    const target = join(containerContext.appRoot, relative(repoRootOf(addon), addon))
    await mkdir(dirname(target), { recursive: true })
    await copyFile(addon, target)
  }
  return { ...net, relayBinary: await ensureRelayBinary() }
}

/// Starts the relays and waits for them. Non-fatal like the rest of the
/// cloud piece: without relays the tunnel still connects directly.
export async function launchDevNet({ net, repoRoot, cloudPort, containerized }) {
  const processes = await startDevRelays({
    net,
    repoRoot,
    relayBinary: net.relayBinary,
    cloudPort,
    containerized
  })
  if (await waitForDevRelays(net)) {
    console.log(`  relays:   ${net.relays.map((relay) => relay.url).join("  ")}`)
  } else {
    console.error("Dev tunnel relays did not become healthy; the tunnel runs direct-only.")
  }
  return processes
}

/// Trust for the dev CA. Host processes and the apps read the file (a PEM
/// can't travel through `open --env`, which escapes its newlines); machines
/// that may run in a container, which can't see host paths, also get it
/// inline (an unreadable file is skipped there).
export const devNetEnvironment = async (net, { inline = false } = {}) => ({
  CODEVISOR_NET_CA_FILE: net.caFile,
  ...(inline ? { CODEVISOR_NET_CA_PEM: await readFile(net.caFile, "utf8") } : {})
})
