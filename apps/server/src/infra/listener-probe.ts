import { connect, type NetConnectOpts, type Socket } from "node:net"

// A wildcard bind can shadow another loopback server, so probe before binding.
export const hasExistingListener = (
  host: string,
  port: number,
  dial: (options: NetConnectOpts) => Socket = connect
): Promise<boolean> =>
  new Promise((resolve) => {
    const probeHost = host === "0.0.0.0" || host === "::" ? "127.0.0.1" : host
    const socket = dial({ host: probeHost, port })
    const done = (listening: boolean): void => {
      socket.destroy()
      resolve(listening)
    }
    socket.once("connect", () => done(true))
    socket.once("error", () => done(false))
    socket.setTimeout(1_000, () => done(false))
  })
