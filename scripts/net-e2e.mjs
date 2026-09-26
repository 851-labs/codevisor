// Multi-process tunnel test (docs/plans/codevisor-tunnel.md): real wrangler
// (local D1 + Durable Objects), two real relays launched exactly like
// `bun run dev` (scripts/dev-net.mjs), two real servers, and a headless app
// that dials the machines through the tunnel and makes sealed HTTP calls.
//
// Scenarios:
//   1. relay-only machine: the call rides the relay; both relays restart
//      mid-connection and a second call still succeeds on the same connection.
//   2. auto machine: the connection upgrades to a direct path.
//
// Usage: node scripts/net-e2e.mjs   (builds what it needs; ~1 min warm)
import { spawn } from "node:child_process"
import { openSync } from "node:fs"
import { mkdir, rm } from "node:fs/promises"
import { createRequire } from "node:module"
import { join } from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"

import { cloudWranglerEnvironment } from "./dev-cloud.mjs"
import {
  devNetCloudVariables,
  devNetEnvironment,
  ensureDevCertificates,
  resolveDevNet,
  startDevRelays,
  waitForDevRelays
} from "./dev-net.mjs"
import { delay, findAvailablePort } from "./dev-shared.mjs"
import { ensureNodeAddon, ensureRelayBinary } from "./net-artifact.mjs"

const repoRoot = join(fileURLToPath(import.meta.url), "..", "..")
const root = join(repoRoot, "tmp", "net-e2e")
const children = []

const log = (line) => console.log(`[net-e2e] ${line}`)

const run = (command, args, options = {}) =>
  new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: repoRoot, stdio: "inherit", ...options })
    child.on("error", reject)
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`${command} ${args.join(" ")} exited ${code}`))
    )
  })

const start = (command, args, options = {}) => {
  const child = spawn(command, args, { cwd: repoRoot, stdio: "inherit", ...options })
  children.push(child)
  return child
}

const waitFor = async (label, predicate, attempts = 160) => {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const value = await predicate().catch(() => undefined)
    if (value) return value
    await delay(250)
  }
  throw new Error(`timed out waiting for ${label}`)
}

async function main() {
  await rm(root, { recursive: true, force: true })
  await mkdir(root, { recursive: true })
  log("building server and packages")
  await run("npx", ["turbo", "run", "build", "--filter=@codevisor/server"])
  await ensureNodeAddon()
  const relayBinary = await ensureRelayBinary()

  const api = await import("../packages/api/dist/index.js")
  const crypto = await import("../packages/cloud-crypto/dist/index.js")
  const { loadNet, ALPN_CHANNELS } = await import("../packages/net/dist/index.js")
  const WebSocket = createRequire(join(repoRoot, "apps/server/package.json"))("ws")
  const net = loadNet()

  // -- Cloud + relays --------------------------------------------------------
  const cloudPort = await findAvailablePort(47_000, 47_000, 1_000)
  const cloudUrl = `http://127.0.0.1:${cloudPort}`
  const devNet = await resolveDevNet({
    instanceHash: "e2e0e2e0e2",
    netRoot: join(root, "net"),
    relayHost: "127.0.0.1"
  })
  await ensureDevCertificates(devNet)
  const persist = join(root, "wrangler")
  await run(
    "bun",
    [
      "x",
      "wrangler",
      "d1",
      "migrations",
      "apply",
      "codevisor-cloud",
      "--local",
      "--persist-to",
      persist
    ],
    { cwd: join(repoRoot, "apps/cloud"), stdio: "ignore" }
  )
  start(
    "bun",
    [
      "x",
      "wrangler",
      "dev",
      "--port",
      String(cloudPort),
      "--ip",
      "127.0.0.1",
      "--persist-to",
      persist,
      "--var",
      "DEV_AUTH:1",
      "--var",
      `PUBLIC_BASE_URL:${cloudUrl}`,
      ...devNetCloudVariables(devNet),
      "--show-interactive-dev-session=false"
    ],
    {
      cwd: join(repoRoot, "apps/cloud"),
      env: cloudWranglerEnvironment(),
      stdio: [
        "ignore",
        openSync(join(root, "wrangler.log"), "a"),
        openSync(join(root, "wrangler.log"), "a")
      ]
    }
  )
  await waitFor("cloud", async () => (await fetch(`${cloudUrl}/health`)).ok)
  let relays = await startDevRelays({
    net: devNet,
    repoRoot,
    relayBinary,
    cloudPort,
    containerized: false
  })
  children.push(...relays)
  if (!(await waitForDevRelays(devNet))) throw new Error("relays unhealthy")
  const { token } = await (await fetch(`${cloudUrl}/dev/login`, { method: "POST" })).json()
  log(`cloud ${cloudUrl}, relays ${devNet.relays.map((relay) => relay.url).join(" ")}`)

  // -- Machines --------------------------------------------------------------
  const netEnvironment = await devNetEnvironment(devNet, { inline: true })
  const startMachine = async (name, pathPolicy, port) => {
    const data = join(root, name, "data")
    for (const dir of ["data", "logs", "worktrees", "repos", "plugins", "tmp"]) {
      await mkdir(join(root, name, dir), { recursive: true })
    }
    start(
      "node",
      [
        join(repoRoot, "apps/server/dist/main.js"),
        "serve",
        "--host",
        "127.0.0.1",
        "--port",
        String(port),
        "--db",
        join(data, "codevisor-server.sqlite"),
        "--auth",
        "token",
        "--kind",
        "remote",
        "--name",
        name
      ],
      {
        env: {
          ...process.env,
          ...netEnvironment,
          TMPDIR: join(root, name, "tmp"),
          CODEVISOR_DATA_DIR: data,
          CODEVISOR_LOGS_DIR: join(root, name, "logs"),
          CODEVISOR_WORKTREES_ROOT: join(root, name, "worktrees"),
          CODEVISOR_REPOS_ROOT: join(root, name, "repos"),
          CODEVISOR_PLUGINS_ROOT: join(root, name, "plugins"),
          CODEVISOR_DEV_CLOUD_URL: cloudUrl,
          CODEVISOR_DEV_CLOUD_TOKEN: token,
          CODEVISOR_NET_PATH_POLICY: pathPolicy
        }
      }
    )
  }
  await startMachine("E2E Relayed", "relay-only", await findAvailablePort(48_000, 48_000, 500))
  await startMachine("E2E Direct", "auto", await findAvailablePort(48_500, 48_500, 500))

  // -- Headless app ----------------------------------------------------------
  const appKeys = crypto.generateDeviceKeyPair()
  const tunnelSecret = net.generateSecretKeyHex()
  const tunnelEndpointId = net.endpointIdForSecretKey(tunnelSecret)
  const deviceId = `e2e-app-${Date.now()}`
  const hub = new WebSocket(`${cloudUrl.replace(/^http/, "ws")}/connect`, {
    headers: { authorization: `Bearer ${token}`, "x-codevisor-tunnel-endpoint": tunnelEndpointId }
  })
  const machines = new Map()
  let welcome
  hub.on("message", (data, isBinary) => {
    if (isBinary) return
    const frame = api.decodeHubToApp(data.toString())
    if (frame.t === "welcome") {
      welcome = frame
      for (const machine of frame.machines) machines.set(machine.name, machine)
    }
    if (frame.t === "presence") machines.set(frame.machine.name, frame.machine)
  })
  await new Promise((resolve, reject) => {
    hub.on("open", resolve)
    hub.on("error", reject)
  })
  hub.send(
    api.encodeCloudFrame({
      t: "hello",
      protocol: api.CLOUD_PROTOCOL_VERSION,
      device: {
        deviceId,
        kind: "app",
        name: "net-e2e",
        publicKey: appKeys.publicKey,
        tunnelEndpointId
      }
    })
  )
  await waitFor("welcome", async () => welcome)
  if (welcome.tunnel !== "on") throw new Error(`tunnel rollout is ${welcome.tunnel}`)
  const app = await net.TunnelEndpoint.bind({
    secretKeyHex: tunnelSecret,
    relays: welcome.relays,
    trustAnchorsPem: [netEnvironment.CODEVISOR_NET_CA_PEM],
    pathPolicy: "auto",
    alpns: [ALPN_CHANNELS]
  })

  /// Dials a machine's tunnel, completes the channel-protocol hello, and
  /// returns a function making sealed HTTP GETs over it.
  const dial = async (name) => {
    const machine = await waitFor(`${name} tunnel address`, async () => {
      const presence = machines.get(name)
      return presence?.online && presence.tunnel?.relayUrl !== undefined ? presence : undefined
    })
    const connection = await app.connect(machine.tunnel, ALPN_CHANNELS)
    const stream = await connection.openMessageStream()
    const inbox = []
    const waiters = []
    void (async () => {
      for (;;) {
        const message = await stream.recv().catch(() => null)
        if (message === null) return
        const waiter = waiters.shift()
        if (waiter === undefined) inbox.push(message)
        else waiter(message)
      }
    })()
    const next = () =>
      inbox.length > 0
        ? Promise.resolve(inbox.shift())
        : new Promise((resolve) => waiters.push(resolve))
    await stream.send(
      0,
      Buffer.from(
        api.encodeCloudFrame({
          t: "hello",
          protocol: api.CLOUD_PROTOCOL_VERSION,
          device: {
            deviceId,
            kind: "app",
            name: "net-e2e",
            publicKey: appKeys.publicKey,
            tunnelEndpointId
          }
        })
      )
    )
    const hello = await next()
    if (!hello.payload.toString().includes('"welcome"')) {
      throw new Error(`machine refused the tunnel hello: ${hello.payload.toString()}`)
    }
    let channels = 0
    const get = async (path) => {
      const channelId = `e2e-${++channels}`
      const opened = crypto.openChannel(appKeys.secretKey, machine.publicKey)
      const send = (frame, payload) =>
        stream.send(
          1,
          Buffer.from(
            api.encodeRelayEnvelopes([{ header: { machineId: machine.deviceId, frame }, payload }])
          )
        )
      await send(
        { t: "open", channelId, seq: 0, ephemeralKey: opened.ephemeralPublicKey },
        crypto.sealJson(opened.cipher, channelId, "opener-to-responder", 0, {
          channelType: "http",
          params: { method: "GET", path, headers: {} }
        })
      )
      await send(
        { t: "data", channelId, seq: 1 },
        crypto.sealJson(opened.cipher, channelId, "opener-to-responder", 1, { kind: "end" })
      )
      let status
      let body = ""
      for (;;) {
        const message = await next()
        for (const envelope of api.decodeRelayEnvelopes(message.payload)) {
          const frame = envelope.header.frame
          if (frame.channelId !== channelId) continue
          if (frame.t === "close") return { status, body }
          if (frame.t !== "data") continue
          const value = crypto.openJson(
            opened.cipher,
            channelId,
            "responder-to-opener",
            frame.seq,
            envelope.payload
          )
          if (value.kind === "head") status = value.status
          if (value.kind === "chunk")
            body += Buffer.from(crypto.fromBase64Url(value.data)).toString()
        }
      }
    }
    return { connection, get }
  }

  const expectInfo = async (label, get) => {
    const response = await get("/v1/info")
    if (response.status !== 200 || !response.body.includes('"version"')) {
      throw new Error(
        `${label}: unexpected /v1/info response ${response.status} ${response.body.slice(0, 200)}`
      )
    }
    log(`${label}: GET /v1/info -> ${response.status}`)
  }

  // Scenario 1: relayed, surviving a restart of every relay.
  const relayed = await dial("E2E Relayed")
  await expectInfo("relayed", relayed.get)
  const relayedPaths = relayed.connection.paths()
  if (relayedPaths.length === 0 || !relayedPaths.every((path) => path.isRelay)) {
    throw new Error(`relayed machine used a direct path: ${JSON.stringify(relayedPaths)}`)
  }
  log("restarting both relays")
  for (const relay of relays) relay.kill("SIGTERM")
  await Promise.all(relays.map((relay) => new Promise((resolve) => relay.once("exit", resolve))))
  relays = await startDevRelays({
    net: devNet,
    repoRoot,
    relayBinary,
    cloudPort,
    containerized: false
  })
  children.push(...relays)
  if (!(await waitForDevRelays(devNet))) throw new Error("relays unhealthy after restart")
  await expectInfo("relayed after relay restart (same connection)", relayed.get)

  // Scenario 2: direct upgrade.
  const direct = await dial("E2E Direct")
  await expectInfo("direct", direct.get)
  await waitFor("a selected direct path", async () =>
    direct.connection.paths().some((path) => path.selected && !path.isRelay)
  )
  log(
    `direct paths: ${JSON.stringify(direct.connection.paths().map((path) => [path.isRelay ? "relay" : "ip", path.selected]))}`
  )

  hub.close()
  await app.close()
  log("PASS")
}

main()
  .catch((error) => {
    console.error(`[net-e2e] FAIL: ${error instanceof Error ? error.stack : error}`)
    process.exitCode = 1
  })
  .finally(() => {
    for (const child of children) child.kill("SIGTERM")
  })
