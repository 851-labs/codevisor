/// Relay channel used for an opaque byte stream to the machine's own
/// Codevisor loopback listener. The service name is deliberately fixed: this
/// is not a general-purpose TCP proxy and peers never supply a host or port.
export const BYTE_STREAM_CHANNEL_TYPE = "byte-stream"
export const CODEVISOR_LOOPBACK_SERVICE = "codevisor-loopback"
export const BYTE_STREAM_PROTOCOL_VERSION = 1

/// Bound individual encrypted relay messages well below the hub frame limit.
export const BYTE_STREAM_MAX_CHUNK_BYTES = 64 * 1024

/// Per-direction in-flight ciphertext budget. Credit is measured in the
/// base64url box bytes carried by the relay protocol, not plaintext bytes.
export const BYTE_STREAM_INITIAL_CREDIT_BYTES = 1024 * 1024

/// ChaCha20-Poly1305 appends a 16-byte tag; unpadded base64url encodes the
/// resulting box in ceil(n * 4 / 3) ASCII bytes.
export const byteStreamSealedBytes = (plaintextBytes: number): number => {
  if (!Number.isSafeInteger(plaintextBytes) || plaintextBytes < 0) {
    throw new Error("invalid plaintext byte count")
  }
  return Math.ceil(((plaintextBytes + 16) * 4) / 3)
}

export interface ByteStreamChannelParams {
  service: typeof CODEVISOR_LOOPBACK_SERVICE
  version: typeof BYTE_STREAM_PROTOCOL_VERSION
}

export const codevisorLoopbackParams = (): ByteStreamChannelParams => ({
  service: CODEVISOR_LOOPBACK_SERVICE,
  version: BYTE_STREAM_PROTOCOL_VERSION
})

export const parseByteStreamChannelParams = (
  value: unknown
): ByteStreamChannelParams | undefined => {
  if (typeof value !== "object" || value === null) return undefined
  const record = value as Record<string, unknown>
  if (
    record.service !== CODEVISOR_LOOPBACK_SERVICE ||
    record.version !== BYTE_STREAM_PROTOCOL_VERSION
  ) {
    return undefined
  }
  return codevisorLoopbackParams()
}
