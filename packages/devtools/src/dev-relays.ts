import { type ChildProcess, spawn } from "node:child_process"
import { mkdir, readFile, writeFile } from "node:fs/promises"
import https from "node:https"
import { join } from "node:path"

import { delay } from "./child-processes.ts"

export interface RelayPorts {
  readonly https: number
  readonly quic: number
  readonly router: number
  readonly internal: number
  readonly metrics: number
}

export interface DevRelay {
  readonly name: string
  readonly host: string
  readonly bind?: string | undefined
  readonly url: string
  readonly ports: RelayPorts
}

export interface DevRelayNet {
  readonly relayHost: string
  readonly relays: ReadonlyArray<DevRelay>
  readonly netRoot: string
  readonly caFile: string
  readonly authorizeToken: string
}

export async function startDevRelays(options: {
  readonly net: DevRelayNet
  readonly repoRoot: string
  readonly relayBinary: string
  readonly cloudPort: number
  readonly containerized: boolean
}): Promise<Array<ChildProcess>> {
  const processes: Array<ChildProcess> = []
  for (const relay of options.net.relays) processes.push(...(await startRelay(options, relay)))
  return processes
}

export function relayHealthUrl(relay: DevRelay): string {
  return `https://127.0.0.1:${relay.ports.https}`
}

export function relayHealthy(
  url: string,
  ca: string | Buffer | undefined,
  timeoutMs = 1000
): Promise<boolean> {
  return new Promise((resolve) => {
    let settled = false
    let request: ReturnType<typeof https.request> | undefined
    const settle = (value: boolean) => {
      if (settled) return
      settled = true
      clearTimeout(deadline)
      request?.destroy()
      resolve(value)
    }
    const deadline = setTimeout(() => settle(false), timeoutMs)
    try {
      request = https.request(`${url}/healthz`, { ca, timeout: timeoutMs }, (response) => {
        response.resume()
        settle(response.statusCode === 200)
      })
    } catch {
      settle(false)
      return
    }
    request.on("error", () => settle(false))
    request.on("timeout", () => settle(false))
    request.on("close", () => settle(false))
    request.end()
  })
}

export async function waitForDevRelays(
  net: DevRelayNet,
  {
    attempts = 80,
    intervalMs = 250,
    probeTimeoutMs
  }: { attempts?: number; intervalMs?: number; probeTimeoutMs?: number } = {}
): Promise<boolean> {
  const ca = await readFile(net.caFile)
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const probes = net.relays.flatMap((relay) => [
      relayHealthy(relayHealthUrl(relay), ca, probeTimeoutMs),
      routerHealthy(relay, probeTimeoutMs)
    ])
    if ((await Promise.all(probes)).every(Boolean)) return true

    await delay(intervalMs)
  }
  return false
}

async function startRelay(
  options: {
    readonly net: DevRelayNet
    readonly repoRoot: string
    readonly relayBinary: string
    readonly cloudPort: number
    readonly containerized: boolean
  },
  relay: DevRelay
): Promise<Array<ChildProcess>> {
  const { net, repoRoot } = options
  const directory = join(net.netRoot, relay.name)
  await mkdir(join(directory, "acme-webroot"), { recursive: true })
  const bind = relay.bind ?? (options.containerized ? "0.0.0.0" : "127.0.0.1")
  const environment = relayEnvironment(net, relay, bind, options.cloudPort)
  const configPath = join(directory, "iroh-relay.toml")
  await writeFile(configPath, await renderConfig(repoRoot, environment))
  return [
    spawn(options.relayBinary, ["--config-path", configPath], {
      env: environment,
      stdio: ["ignore", "inherit", "inherit"]
    }),
    spawn("python3", [join(repoRoot, "apps/relay/port80-router.py")], {
      env: {
        ...environment,
        ROUTER_HOST: bind,
        ROUTER_PORT: String(relay.ports.router),
        ACME_WEBROOT: join(directory, "acme-webroot")
      },
      stdio: ["ignore", "inherit", "inherit"]
    })
  ]
}

function relayEnvironment(
  net: DevRelayNet,
  relay: DevRelay,
  bind: string,
  cloudPort: number
): NodeJS.ProcessEnv {
  return {
    ...process.env,
    RELAY_HOSTNAME: relay.host ?? net.relayHost,
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
}

function renderConfig(repoRoot: string, environment: NodeJS.ProcessEnv): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn("sh", [join(repoRoot, "apps/relay/render-config.sh")], {
      env: environment,
      stdio: ["ignore", "pipe", "inherit"]
    })
    let output = ""
    child.stdout.on("data", (chunk: Buffer) => {
      output += chunk.toString()
    })
    child.on("error", reject)
    child.on("exit", (code) =>
      code === 0 ? resolve(output) : reject(new Error(`render-config.sh exited ${code}`))
    )
  })
}

async function routerHealthy(relay: DevRelay, timeoutMs = 1000): Promise<boolean> {
  try {
    const response = await fetch(`http://127.0.0.1:${relay.ports.router}/generate_204`, {
      signal: AbortSignal.timeout(timeoutMs)
    })
    return response.status === 204
  } catch {
    return false
  }
}
