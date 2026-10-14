export const BYTE_STREAM_CHANNEL_TYPE = "byte-stream"
export const CODEVISOR_LOOPBACK_SERVICE = "codevisor-loopback"
export const BYTE_STREAM_PROTOCOL_VERSION = 1

export const BYTE_STREAM_MAX_CHUNK_BYTES = 64 * 1024

export const BYTE_STREAM_INITIAL_CREDIT_BYTES = 1024 * 1024

export const byteStreamSealedBytes = (plaintextBytes: number): number => {
  if (!Number.isSafeInteger(plaintextBytes) || plaintextBytes < 0) {
    throw new Error("invalid plaintext byte count")
  }
  return plaintextBytes + 16
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
