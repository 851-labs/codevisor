import { createServer as createHttpServer, type Server } from "node:http"
import { createServer } from "node:net"

import { afterEach, describe, expect, it, vi } from "vitest"

import { listeningPort } from "../test-support-net.js"
import { hasExistingListener } from "./listener-probe.js"
import { claimPort, loopbackIsFreeOn } from "./port-claim.js"

const open: Array<{ close: (done: () => void) => unknown }> = []

const listenOn = async (host: string): Promise<number> => {
  const holder = createServer()
  open.push(holder)
  await new Promise<void>((resolve) => holder.listen(0, host, resolve))
  return listeningPort(holder)
}

const freshServer = (): Server => {
  const server = createHttpServer()
  open.push(server)
  return server
}

afterEach(async () => {
  for (const server of open.splice(0)) await new Promise<void>((done) => server.close(done))
})

describe("claimPort", () => {
  it("binds the first candidate that is free", async () => {
    const taken = await listenOn("127.0.0.1")
    const server = freshServer()

    const port = await claimPort(server, { host: "127.0.0.1", candidates: [taken, 0] })

    expect(port).not.toBe(taken)
    expect(listeningPort(server)).toBe(port)
  })

  it("names every port it tried when all are taken", async () => {
    const first = await listenOn("127.0.0.1")
    const second = await listenOn("127.0.0.1")

    await expect(
      claimPort(freshServer(), { host: "127.0.0.1", candidates: [first, second] })
    ).rejects.toThrow(`Every port Codevisor tried on 127.0.0.1 is taken (${first}, ${second})`)
  })

  it("rejects bind failures that another port would not fix", async () => {
    await expect(
      claimPort(freshServer(), { host: "192.0.2.1", candidates: [0, 0] })
    ).rejects.toMatchObject({ code: "EADDRNOTAVAIL" })
  })

  it("gives up a wildcard port whose loopback address another app answers", async () => {
    const server = freshServer()
    const checked: Array<number> = []
    const loopbackIsOurs = vi.fn(async (port: number) => {
      checked.push(port)
      return checked.length > 1
    })

    const port = await claimPort(server, { host: "0.0.0.0", candidates: [0, 0], loopbackIsOurs })

    expect(checked).toHaveLength(2)
    expect(port).toBe(checked[1])
    expect(await hasExistingListener("127.0.0.1", checked[0]!)).toBe(false)
  })

  it("trusts a specific host's bind without a loopback check", async () => {
    const loopbackIsOurs = vi.fn(async () => false)

    await claimPort(freshServer(), { host: "127.0.0.1", candidates: [0], loopbackIsOurs })

    expect(loopbackIsOurs).not.toHaveBeenCalled()
  })

  it("checks loopback with the current platform's rules by default", async () => {
    const server = freshServer()

    const port = await claimPort(server, { host: "0.0.0.0", candidates: [0] })

    expect(listeningPort(server)).toBe(port)
  })
})

describe("loopbackIsFreeOn", () => {
  it("sees another app's loopback listener on platforms that share wildcard ports", async () => {
    const squatted = await listenOn("127.0.0.1")

    expect(await loopbackIsFreeOn("darwin")(squatted)).toBe(false)
  })

  it("releases its guard after finding loopback free", async () => {
    expect(await loopbackIsFreeOn("darwin")(0)).toBe(true)
  })

  it("relies on the wildcard bind where the kernel already rejects overlaps", async () => {
    const squatted = await listenOn("127.0.0.1")

    expect(await loopbackIsFreeOn("linux")(squatted)).toBe(true)
  })
})
