import { isRecord } from "@codevisor/api"

export interface PeerKeyPinStore {
  get(deviceId: string): string | undefined
  set(deviceId: string, publicKey: string): void
}

export interface PeerKeyPinFile {
  version: 1
  peers: Record<string, string>
}

export const parsePeerKeyPins = (raw: string): Record<string, string> => {
  try {
    const parsed: unknown = JSON.parse(raw)
    if (!isRecord(parsed) || parsed.version !== 1 || !isRecord(parsed.peers)) {
      return {}
    }
    const peers: Record<string, string> = {}
    for (const [deviceId, publicKey] of Object.entries(parsed.peers)) {
      if (typeof publicKey === "string") peers[deviceId] = publicKey
    }
    return peers
  } catch {
    return {}
  }
}

export const serializePeerKeyPins = (peers: Readonly<Record<string, string>>): string =>
  JSON.stringify({ version: 1, peers } satisfies PeerKeyPinFile, null, 2)

export const makePeerKeyPinStore = (options: {
  initial?: Readonly<Record<string, string>>
  persist?: (peers: Readonly<Record<string, string>>) => void
}): PeerKeyPinStore => {
  const peers = new Map(Object.entries(options.initial ?? {}))
  return {
    get: (deviceId) => peers.get(deviceId),
    set: (deviceId, publicKey) => {
      if (peers.has(deviceId)) return
      peers.set(deviceId, publicKey)
      options.persist?.(Object.fromEntries(peers))
    }
  }
}
