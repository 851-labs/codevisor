import { Socket, type AddressInfo } from "node:net"
import type { Duplex } from "node:stream"

export const listeningPort = (server: { address(): string | AddressInfo | null }): number => {
  const address = server.address()
  if (address === null || typeof address === "string") {
    throw new Error("The server is not listening on a TCP port")
  }
  return address.port
}

export const tcpSocket = (socket: Duplex): Socket => {
  if (!(socket instanceof Socket)) throw new Error("Expected a TCP socket")
  return socket
}

export class FakeSocket extends Socket {
  readonly writes: Array<Uint8Array | string> = []
  readonly endings: Array<Uint8Array | string | undefined> = []
  readonly pipes: NodeJS.WritableStream[] = []
  onTimeout: (() => void) | undefined

  override setTimeout(milliseconds: number, callback?: () => void): this {
    this.onTimeout = milliseconds === 0 ? undefined : callback
    return this
  }

  override setNoDelay(): this {
    return this
  }

  override write(data: Uint8Array | string): boolean {
    this.writes.push(data)
    return true
  }

  override end(data?: Uint8Array | string | (() => void)): this {
    this.endings.push(typeof data === "function" ? undefined : data)
    return this
  }

  override pipe<T extends NodeJS.WritableStream>(destination: T): T {
    this.pipes.push(destination)
    return destination
  }

  override destroy(): this {
    if (!this.destroyed) {
      Object.defineProperty(this, "destroyed", { value: true })
      this.emit("close")
    }
    return this
  }
}
