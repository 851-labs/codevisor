import { request as httpRequest } from "node:http"
import { connect, createServer } from "node:net"

/// Asks the kernel for a free loopback port. A race against another process
/// binding it before the plugin does is possible but harmless: startup fails
/// readiness and surfaces as a plugin error, never a hijack (the plugin binds
/// loopback).
export const allocatePort = (): Promise<number> =>
  new Promise((resolve, reject) => {
    const probe = createServer()
    /* v8 ignore next -- loopback ephemeral binds only fail under fd exhaustion. */
    probe.once("error", reject)
    probe.listen(0, "127.0.0.1", () => {
      const address = probe.address()
      /* v8 ignore next -- TCP listen always returns AddressInfo here. */
      const port = typeof address === "object" && address !== null ? address.port : 0
      probe.close(() => resolve(port))
    })
  })

export const tcpProbe = (port: number): Promise<boolean> =>
  new Promise((resolve) => {
    const socket = connect({ host: "127.0.0.1", port })
    const done = (up: boolean): void => {
      socket.destroy()
      resolve(up)
    }
    socket.once("connect", () => done(true))
    socket.once("error", () => done(false))
    /* v8 ignore next -- loopback connects resolve or error immediately. */
    socket.setTimeout(1_000, () => done(false))
  })

export const httpProbe = (port: number, path: string): Promise<boolean> =>
  new Promise((resolve) => {
    let settled = false
    const done = (ready: boolean): void => {
      if (settled) return
      settled = true
      resolve(ready)
    }
    const probe = httpRequest(
      { host: "127.0.0.1", method: "GET", path, port, timeout: 1_000 },
      (response) => {
        response.resume()
        done(
          response.statusCode !== undefined &&
            response.statusCode >= 200 &&
            response.statusCode < 300
        )
      }
    )
    probe.once("error", () => done(false))
    probe.once("timeout", () => {
      probe.destroy()
      done(false)
    })
    probe.end()
  })
