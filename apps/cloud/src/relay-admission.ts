import {
  decodeRelayEnvelopes,
  MAX_RELAY_MESSAGE_BYTES,
  type WireRelayEnvelope
} from "@codevisor/api"

/// Admit a binary relay batch before the hub counts or routes it. Size and
/// hello checks precede decoding; accepted payloads remain views of the input.
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
