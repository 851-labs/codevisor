// Also run under Bun (dev:scripts:test): the dev runner runs on Bun, whose
// node:https differs from Node where it matters here (see relayHealthy).

import assert from "node:assert/strict"
import { mkdtemp, rm, writeFile } from "node:fs/promises"
import https from "node:https"
import { createServer } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import { rootCertificates } from "node:tls"

import { relayHealthUrl, relayHealthy, waitForDevRelays } from "./dev-net.mjs"

/// A TCP server that accepts connections and never answers: the TLS
/// handshake stalls, like an address that swallows packets.
const silentServer = async () => {
  const sockets = new Set()
  const server = createServer((socket) => {
    sockets.add(socket)
    socket.on("close", () => sockets.delete(socket))
  })
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
  return {
    port: server.address().port,
    close: () =>
      new Promise((resolve) => {
        for (const socket of sockets) socket.destroy()
        server.close(resolve)
      })
  }
}

test("a relay probe that never gets an answer settles false within its timeout", async () => {
  const server = await silentServer()
  try {
    const startedAt = Date.now()
    const healthy = await relayHealthy(`https://127.0.0.1:${server.port}`, undefined, 200)
    assert.equal(healthy, false)
    assert.ok(Date.now() - startedAt < 2000, "the probe must not outlive its timeout")
  } finally {
    await server.close()
  }
})

test("waiting on relays that never answer gives up after its attempts", async () => {
  const server = await silentServer()
  const netRoot = await mkdtemp(join(tmpdir(), "dev-net-"))
  try {
    const caFile = join(netRoot, "ca.pem")
    // A well-formed CA, so the wait reaches the never-answering server
    // instead of failing on the certificate first.
    await writeFile(caFile, rootCertificates[0])
    const net = {
      caFile,
      relays: [
        {
          name: "relay-1",
          // The container-facing address may not exist on the host yet; the
          // host must never wait on it.
          url: "https://192.0.2.1:1",
          ports: { https: server.port, router: server.port }
        }
      ]
    }
    const startedAt = Date.now()
    const healthy = await waitForDevRelays(net, {
      attempts: 3,
      intervalMs: 10,
      probeTimeoutMs: 100
    })
    assert.equal(healthy, false)
    assert.ok(Date.now() - startedAt < 3000, "the wait must stay bounded")
  } finally {
    await server.close()
    await rm(netRoot, { recursive: true, force: true })
  }
})

test("a relay probe passes its CA and handles a request constructor that throws", async () => {
  const ca = Buffer.from("not a certificate")
  const originalRequest = https.request
  const calls = []
  https.request = (...args) => {
    calls.push(args)
    throw new Error("invalid TLS options")
  }
  try {
    const healthy = await relayHealthy("https://relay.example", ca, 200)
    assert.equal(healthy, false)
    assert.equal(calls.length, 1)
    assert.equal(calls[0][0], "https://relay.example/healthz")
    assert.equal(calls[0][1].ca, ca)
  } finally {
    https.request = originalRequest
  }
})

test("the host checks relays over loopback, not the container-facing address", () => {
  const relay = { url: "https://192.168.64.1:30290", ports: { https: 30290 } }
  assert.equal(relayHealthUrl(relay), "https://127.0.0.1:30290")
})
