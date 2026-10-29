import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { access, copyFile, mkdir, readFile, writeFile } from "node:fs/promises"
import https from "node:https"
import { networkInterfaces } from "node:os"
import { dirname, join, relative } from "node:path"
import { fileURLToPath } from "node:url"

import { delay, isPortAvailable } from "./dev-shared.mjs"

const repoRootOf = () => join(dirname(fileURLToPath(import.meta.url)), "..")

const RELAYS = 2
const PORTS_PER_RELAY = 5

const exists = (path) =>
  access(path).then(
    () => true,
    () => false
  )

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

export async function resolveDevNet({ instanceHash, netRoot, relayHost, vmHost }) {
  const hosts = relayHosts(relayHost, vmHost)
  const slots = Math.floor(1000 / hosts.length)
  let slot = Number.parseInt(instanceHash.slice(0, 8), 16) % slots
  for (let attempt = 0; attempt < slots; attempt += 1, slot = (slot + 1) % slots) {
    const base = 30_000 + slot * hosts.length * PORTS_PER_RELAY
    const ports = Array.from({ length: hosts.length * PORTS_PER_RELAY }, (_, index) => base + index)
    if ((await Promise.all(ports.map((port) => isPortAvailable(port)))).every(Boolean)) {
      const relays = hosts.map(({ name, host, bind }, index) => {
        const [httpsPort, quic, router, internal, metrics] = ports.slice(
          index * PORTS_PER_RELAY,
          (index + 1) * PORTS_PER_RELAY
        )
        return {
          name,
          host,
          bind,
          url: `https://${host}:${httpsPort}`,
          ports: { https: httpsPort, quic, router, internal, metrics }
        }
      })
      return {
        relayHost,
        vmHost,
        relays,
        netRoot,
        caFile: join(netRoot, "ca.pem"),
        authorizeToken: `dev-relay-${createHash("sha256").update(instanceHash).digest("hex").slice(0, 24)}`
      }
    }
  }
  throw new Error("No free port range for the dev tunnel relays")
}

const relayHosts = (relayHost, vmHost) => {
  const shared = Array.from({ length: RELAYS }, (_, index) => ({
    name: `relay-${index + 1}`,
    host: relayHost
  }))
  if (vmHost === undefined) return shared
  return [...shared, { name: "relay-vm", host: vmHost, bind: "0.0.0.0" }]
}

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

const certificateDigest = "-sha256"

export async function ensureDevCertificates(net) {
  const names = [
    ...new Set(["localhost", "127.0.0.1", "::1", net.relayHost, net.vmHost].filter(Boolean))
  ]
  const dir = net.netRoot
  await mkdir(dir, { recursive: true })
  const namesFile = join(dir, "cert-names.json")
  const fingerprint = JSON.stringify({ names, digest: certificateDigest })
  const current = await readFile(namesFile, "utf8").catch(() => "")
  if (current === fingerprint && (await exists(join(dir, "relay.key")))) return
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
    certificateDigest,
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
    certificateDigest,
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
    certificateDigest,
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
    certificateDigest,
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
  await writeFile(namesFile, fingerprint)
}

export async function startDevRelays({ net, repoRoot, relayBinary, cloudPort, containerized }) {
  const bind = containerized ? "0.0.0.0" : "127.0.0.1"
  const processes = []
  for (const relay of net.relays) {
    const dir = join(net.netRoot, relay.name)
    await mkdir(join(dir, "acme-webroot"), { recursive: true })
    const relayBind = relay.bind ?? bind
    const relayEnvironment = {
      ...process.env,
      RELAY_HOSTNAME: relay.host ?? net.relayHost,
      RELAY_CERT_PATH: join(net.netRoot, "relay.pem"),
      RELAY_KEY_PATH: join(net.netRoot, "relay.key"),
      RELAY_AUTHORIZE_URL: `http://127.0.0.1:${cloudPort}/api/relay/authorize`,
      RELAY_AUTHORIZE_TOKEN: net.authorizeToken,
      RELAY_HTTP_BIND_ADDR: `127.0.0.1:${relay.ports.internal}`,
      RELAY_HTTPS_BIND_ADDR: `${relayBind}:${relay.ports.https}`,
      RELAY_QUIC_BIND_ADDR: `${relayBind}:${relay.ports.quic}`,
      RELAY_METRICS_BIND_ADDR: `127.0.0.1:${relay.ports.metrics}`,
      RUST_LOG: process.env.CODEVISOR_DEV_RELAY_LOG ?? "warn"
    }
    const config = await new Promise((resolve, reject) => {
      const child = spawn("sh", [join(repoRoot, "apps/relay/render-config.sh")], {
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
      spawn("python3", [join(repoRoot, "apps/relay/port80-router.py")], {
        env: {
          ...relayEnvironment,
          ROUTER_HOST: relayBind,
          ROUTER_PORT: String(relay.ports.router),
          ACME_WEBROOT: join(dir, "acme-webroot")
        },
        stdio: ["ignore", "inherit", "inherit"]
      })
    )
  }
  return processes
}

export const relayHealthy = (url, ca, timeoutMs = 1000) =>
  new Promise((resolve) => {
    let settled = false
    let deadline
    let req
    const settle = (value) => {
      if (settled) return
      settled = true
      clearTimeout(deadline)
      req?.destroy()
      resolve(value)
    }
    deadline = setTimeout(() => settle(false), timeoutMs)
    try {
      req = https.request(`${url}/healthz`, { ca, timeout: timeoutMs }, (response) => {
        response.resume()
        settle(response.statusCode === 200)
      })
    } catch {
      settle(false)
      return
    }
    req.on("error", () => settle(false))
    req.on("timeout", () => settle(false))
    req.on("close", () => settle(false))
    req.end()
  })

const routerHealthy = (relay, timeoutMs = 1000) =>
  fetch(`http://127.0.0.1:${relay.ports.router}/generate_204`, {
    signal: AbortSignal.timeout(timeoutMs)
  }).then(
    (response) => response.status === 204,
    () => false
  )

export const relayHealthUrl = (relay) => `https://127.0.0.1:${relay.ports.https}`

export async function waitForDevRelays(
  net,
  { attempts = 80, intervalMs = 250, probeTimeoutMs } = {}
) {
  const ca = await readFile(net.caFile)
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const results = await Promise.all(
      net.relays.flatMap((relay) => [
        relayHealthy(relayHealthUrl(relay), ca, probeTimeoutMs),
        routerHealthy(relay, probeTimeoutMs)
      ])
    )
    if (results.every(Boolean)) return true
    await delay(intervalMs)
  }
  return false
}

export async function prepareDevNet({ instanceHash, netRoot, containerContext, vmHost }) {
  const { ensureLinuxNodeAddon, ensureNodeAddon, ensureRelayBinary } =
    await import("./net-artifact.mjs")
  const relayHost = devRelayHost({
    containerEngine: containerContext?.engine,
    containerHostAddress: containerContext?.hostAddress
  })
  const net = await resolveDevNet({ instanceHash, netRoot, relayHost, vmHost })
  await ensureDevCertificates(net)
  await ensureNodeAddon()
  if (containerContext !== undefined) {
    const addon = await ensureLinuxNodeAddon(containerContext.engine)
    const target = join(containerContext.appRoot, relative(repoRootOf(addon), addon))
    await mkdir(dirname(target), { recursive: true })
    await copyFile(addon, target)
  }
  return { ...net, relayBinary: await ensureRelayBinary() }
}

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

export const devNetCaPem = (net) => readFile(net.caFile, "utf8")

export const devNetEnvironment = async (net, { inline = false } = {}) => {
  const environment = { CODEVISOR_NET_CA_FILE: net.caFile }
  if (!inline) return environment
  return { ...environment, CODEVISOR_NET_CA_PEM: await devNetCaPem(net) }
}
