import {
  decodeRelayEnvelopes,
  MAX_RELAY_MESSAGE_BYTES,
  type WireRelayEnvelope
} from "@codevisor/api"

export const admitRelayMessage = (
  message: ArrayBuffer,
  helloDone: boolean
):
  | WireRelayEnvelope[]
  | "relay message exceeds the size limit"
  | "hello required before relaying"
  | "malformed relay message" => {
  if (message.byteLength > MAX_RELAY_MESSAGE_BYTES) return "relay message exceeds the size limit"
  if (!helloDone) return "hello required before relaying"
  return decodeRelayMessage(message)
}

const decodeRelayMessage = (
  message: ArrayBuffer
): WireRelayEnvelope[] | "malformed relay message" => {
  try {
    return decodeRelayEnvelopes(new Uint8Array(message))
  } catch {
    return "malformed relay message"
  }
}
