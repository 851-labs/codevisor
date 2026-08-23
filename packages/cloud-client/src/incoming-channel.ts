import type { ChannelCloseReason } from "@codevisor/api"

/// An app-opened channel as seen by machine-side handlers. Payloads are
/// sealed/opened transparently; handlers only ever see plaintext values.
export interface IncomingChannel {
  channelId: string
  peerId: string
  channelType: string
  params: unknown
  send(value: unknown): void
  /// Sends opaque plaintext and returns the exact ciphertext budget consumed,
  /// or undefined if the channel is already closed.
  sendBytes(value: Uint8Array): number | undefined
  /// Enables explicit receive-side flow control. Call synchronously from the
  /// channel handler before granting any credit or receiving byte frames.
  deferInboundCredit(): void
  /// Allows the peer to send this many ciphertext bytes.
  grantCredit(bytes: number): void
  close(reason: ChannelCloseReason): void
  onData: ((value: unknown) => void) | null
  onBytes: ((value: Uint8Array, sealedBytes: number) => void) | null
  onCredit: ((bytes: number) => void) | null
  onClosed: ((reason: ChannelCloseReason | "peer-gone") => void) | null
}

export type ChannelHandler = (channel: IncomingChannel) => void
