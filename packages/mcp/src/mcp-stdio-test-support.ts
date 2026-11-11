import { PassThrough, type Readable, type Writable } from "node:stream"

import {
  ReadBuffer,
  serializeMessage,
  type JSONRPCMessage,
  type Transport
} from "@modelcontextprotocol/client"

export interface StdioPipes {
  readonly bridge: { readonly input: Readable; readonly output: Writable }
  readonly client: Transport
}

export const stdioPipes = (): StdioPipes => {
  const toBridge = new PassThrough()
  const fromBridge = new PassThrough()
  return {
    bridge: { input: toBridge, output: fromBridge },
    client: streamTransport(fromBridge, toBridge)
  }
}

const streamTransport = (input: Readable, output: Writable): Transport => {
  const buffer = new ReadBuffer()
  const transport: Transport = {
    start: async () => {
      input.on("data", (chunk: Buffer) => {
        buffer.append(chunk)
        deliver(buffer, (message) => transport.onmessage?.(message))
      })
    },
    send: async (message) => {
      output.write(serializeMessage(message))
    },
    close: async () => {
      output.end()
      transport.onclose?.()
    }
  }
  return transport
}

const deliver = (buffer: ReadBuffer, onMessage: (message: JSONRPCMessage) => void): void => {
  for (let message = buffer.readMessage(); message !== null; message = buffer.readMessage()) {
    onMessage(message)
  }
}
