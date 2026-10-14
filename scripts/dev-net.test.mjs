import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { mkdtemp, rm, writeFile } from "node:fs/promises"
import https from "node:https"
import { createServer } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import { rootCertificates } from "node:tls"

import {
  ensureDevCertificates,
  relayHealthUrl,
  relayHealthy,
  waitForDevRelays
} from "./dev-net.mjs"

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
    await writeFile(caFile, rootCertificates[0])
    const net = {
      caFile,
      relays: [
        {
          name: "relay-1",
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

test("dev relay certificates are signed with SHA-256 by any openssl", async () => {
  const netRoot = await mkdtemp(join(tmpdir(), "dev-net-"))
  try {
    await ensureDevCertificates({ netRoot, relayHost: "127.0.0.1" })
    for (const file of ["ca.pem", "relay.pem"]) {
      const text = execFileSync(
        "openssl",
        ["x509", "-in", join(netRoot, file), "-noout", "-text"],
        {
          encoding: "utf8"
        }
      )
      assert.match(
        text,
        /Signature Algorithm: ecdsa-with-SHA256/,
        `${file} must be signed with SHA-256`
      )
    }
  } finally {
    await rm(netRoot, { recursive: true, force: true })
  }
})
