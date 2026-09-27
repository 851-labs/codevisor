// Relay smoke tests (docs/plans/codevisor-tunnel.md).
//
//   node infra/relays/smoke.mjs --local-image <image> [--engine docker|container]
//     Boots the image exactly as Fly does, but with a throwaway CA (no
//     certbot): /healthz over TLS, the port-80 router, and a relay-only
//     tunnel round trip between two real endpoints through the container.
//
//   node infra/relays/smoke.mjs --relay <id>
//     Against the live hostname: public-CA TLS with ≥14 days left, /healthz,
//     and the router's /generate_204.
import { execFile, spawn } from "node:child_process"
import { mkdir, readFile, rm } from "node:fs/promises"
import { createServer } from "node:http"
import { request } from "node:https"
import { join } from "node:path"
import process from "node:process"
import { connect } from "node:tls"
import { fileURLToPath } from "node:url"
import { promisify } from "node:util"

import { containerHostAddress } from "../../scripts/dev-containers.mjs"
import { ensureDevCertificates } from "../../scripts/dev-net.mjs"
import { delay } from "../../scripts/dev-shared.mjs"
import { readRelays } from "./gen-fly.mjs"

const exec = promisify(execFile)
const repoRoot = fileURLToPath(new URL("../..", import.meta.url))
const argument = (name) => {
  const index = process.argv.indexOf(name)
  return index === -1 ? undefined : process.argv[index + 1]
}

const get = (url, options = {}) =>
  new Promise((resolve) => {
    const lib = url.startsWith("https:") ? request : undefined
    if (lib === undefined) {
      fetch(url).then(
        (response) => resolve(response.status),
        () => resolve(0)
      )
      return
    }
    const req = lib(url, { timeout: 3000, ...options }, (response) => {
      response.resume()
      resolve(response.statusCode)
    })
    req.on("error", () => resolve(0))
    req.on("timeout", () => req.destroy())
    req.end()
  })

/// Retries `check` for up to a minute. A thrown error counts as "not yet":
/// a relay that just deployed can reset its first few connections while
/// Fly's proxy picks up the new Machine.
const until = async (label, check) => {
  let lastError
  for (let attempt = 0; attempt < 120; attempt += 1) {
    try {
      if (await check()) return
    } catch (error) {
      lastError = error
    }
    await delay(500)
  }
  const cause = lastError === undefined ? "" : ` (last error: ${lastError.message})`
  throw new Error(`smoke: timed out waiting for ${label}${cause}`)
}

async function tunnelRoundTrip(relayUrl, anchor) {
  const { loadNet, ALPN_CHANNELS } = await import("../../packages/net/dist/index.js")
  const net = loadNet()
  const bind = () =>
    net.TunnelEndpoint.bind({
      secretKeyHex: net.generateSecretKeyHex(),
      relays: [{ url: relayUrl }],
      trustAnchorsPem: anchor === undefined ? [] : [anchor],
      pathPolicy: "relay-only",
      alpns: [ALPN_CHANNELS]
    })
  const [server, client] = [await bind(), await bind()]
  try {
    await server.online(20_000)
    await client.online(20_000)
    const served = (async () => {
      const connection = await server.accept()
      const stream = await connection.acceptMessageStream()
      const message = await stream.recv()
      await stream.send(message.kind, message.payload)
    })()
    const connection = await client.connect(
      { endpointId: server.endpointId(), relayUrl: server.addr().relayUrl, directAddrs: [] },
      ALPN_CHANNELS
    )
    const stream = await connection.openMessageStream()
    await stream.send(0, Buffer.from("smoke"))
    const echoed = await stream.recv()
    await served
    if (echoed?.payload.toString() !== "smoke") throw new Error("relay round trip failed")
    if (!connection.paths().every((path) => path.isRelay)) throw new Error("expected a relay path")
  } finally {
    await Promise.all([server.close(), client.close()])
  }
}

async function smokeLocalImage(image, engine) {
  const dir = join(repoRoot, "tmp", "relay-smoke")
  await rm(dir, { recursive: true, force: true })
  await mkdir(dir, { recursive: true })
  const net = { relayHost: "localhost", netRoot: dir }
  await ensureDevCertificates(net)
  // The relay admits every endpoint this server is asked about.
  const authorize = createServer((req, res) => {
    res.end(req.headers.authorization === "Bearer smoke-token" ? "true" : "false")
  })
  await new Promise((resolve) => authorize.listen(0, "0.0.0.0", resolve))
  const hostAddress = await containerHostAddress(engine === "container" ? "apple" : "docker")
  const name = `codevisor-relay-smoke-${process.pid}`
  const binary = engine === "container" ? "container" : "docker"
  const mounted = argument("--mount-app")
  const child = spawn(
    binary,
    [
      "run",
      "--rm",
      "--name",
      name,
      ...(mounted === undefined
        ? []
        : [
            "--volume",
            `${join(repoRoot, "infra/relays")}:/app`,
            "--volume",
            `${mounted}:/relay-bin`,
            "--env",
            "PATH=/relay-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "--entrypoint",
            "/app/entrypoint.sh"
          ]),
      // Linux Docker resolves host.docker.internal (the authorize server's
      // address) only when asked to; Docker Desktop and Apple containers
      // always do.
      ...(engine === "docker" ? ["--add-host", "host.docker.internal:host-gateway"] : []),
      "--publish",
      "18443:443",
      "--publish",
      "18080:80",
      "--volume",
      `${dir}:/certs`,
      "--env",
      "RELAY_HOSTNAME=localhost",
      "--env",
      "RELAY_CERT_PATH=/certs/relay.pem",
      "--env",
      "RELAY_KEY_PATH=/certs/relay.key",
      "--env",
      `RELAY_AUTHORIZE_URL=http://${hostAddress}:${authorize.address().port}/authorize`,
      "--env",
      "RELAY_AUTHORIZE_TOKEN=smoke-token",
      "--env",
      "RELAY_METRICS_BIND_ADDR=127.0.0.1:9090",
      image
    ],
    { stdio: "inherit" }
  )
  try {
    const ca = await readFile(join(dir, "ca.pem"))
    await until(
      "/healthz over TLS",
      async () => (await get("https://localhost:18443/healthz", { ca })) === 200
    )
    await until(
      "port-80 router",
      async () => (await get("http://localhost:18080/generate_204")) === 204
    )
    await tunnelRoundTrip("https://localhost:18443", ca.toString())
    console.log("smoke: local image OK (TLS health, router, relay-only round trip)")
  } finally {
    await exec(binary, ["rm", "--force", name]).catch(() => undefined)
    child.kill()
    authorize.close()
  }
}

const certificateDaysLeft = (hostname) =>
  new Promise((resolve, reject) => {
    const socket = connect({ host: hostname, port: 443, servername: hostname }, () => {
      const expires = new Date(socket.getPeerCertificate().valid_to)
      socket.end()
      resolve((expires.getTime() - Date.now()) / 86_400_000)
    })
    socket.on("error", reject)
  })

async function smokeLiveRelay(id) {
  const { relays } = await readRelays()
  const relay = relays.find((entry) => entry.id === id)
  if (relay === undefined) throw new Error(`unknown relay ${id}`)
  await until("/healthz", async () => (await get(`https://${relay.hostname}/healthz`)) === 200)
  await until(
    "port-80 router",
    async () => (await get(`http://${relay.hostname}/generate_204`)) === 204
  )
  let days = 0
  await until("certificate", async () => {
    days = await certificateDaysLeft(relay.hostname)
    return true
  })
  if (days < 14) throw new Error(`certificate expires in ${days.toFixed(1)} days`)
  console.log(`smoke: ${relay.hostname} OK (certificate valid ${days.toFixed(0)} more days)`)
}

const localImage = argument("--local-image")
const relayId = argument("--relay")
if (localImage !== undefined) await smokeLocalImage(localImage, argument("--engine") ?? "docker")
else if (relayId !== undefined) await smokeLiveRelay(relayId)
else
  throw new Error(
    "usage: smoke.mjs --local-image <image> [--engine docker|container] | --relay <id>"
  )
