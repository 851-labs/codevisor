/// TOFU pinning of app-device public keys on the machine side.
///
/// The hub attaches `peerDeviceId` + `peerPublicKey` to channel opens. The
/// machine pins the first key it successfully completes a channel with for
/// each device id and refuses any later open that presents a different key —
/// so a misbehaving relay cannot swap keys on an established pairing to MITM
/// the "end-to-end" encryption. First sight is trusted (that is TOFU); the
/// protection is key *continuity*, mirroring the app side's machine-key pins.
///
/// This module is pure: persistence is injected (apps/server stores the pins
/// beside cloud.json). A legitimate key change (an app reinstalled without its
/// Keychain identity presents a fresh device id, so it never conflicts) should
/// essentially not occur; recovery from a stale pin is deleting the persisted
/// entry on the machine.

export interface PeerKeyPinStore {
  /// The pinned key for an app device id, if one exists.
  get(deviceId: string): string | undefined
  /// Records a first-seen key. Never overwrites an existing pin.
  set(deviceId: string, publicKey: string): void
}

export interface PeerKeyPinFile {
  version: 1
  peers: Record<string, string>
}

/// Parses a persisted pin file, tolerating unknown/corrupt content (returns
/// an empty pin set — TOFU re-establishes; it must never brick the bridge).
export const parsePeerKeyPins = (raw: string): Record<string, string> => {
  try {
    const parsed = JSON.parse(raw) as Partial<PeerKeyPinFile>
    if (parsed.version !== 1 || typeof parsed.peers !== "object" || parsed.peers === null) {
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

/// In-memory pin store with write-behind persistence: `persist` receives the
/// full pin map after each new pin (callers write it to disk best-effort).
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
