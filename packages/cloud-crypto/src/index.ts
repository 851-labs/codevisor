import { chacha20poly1305 } from "@noble/ciphers/chacha.js"
import { x25519 } from "@noble/curves/ed25519.js"
import { hkdf } from "@noble/hashes/hkdf.js"
import { sha256 } from "@noble/hashes/sha2.js"

/// End-to-end encryption for cloud relay channels (see @codevisor/api
/// cloud-protocol). The hub only ever sees box ciphertext — raw bytes
/// carried as relay envelope payloads.
///
/// Key agreement per channel (Noise-IK-flavoured, deliberately minimal):
///   dh1 = X25519(ephemeral, responderStatic)   — forward secrecy
///   dh2 = X25519(openerStatic, responderStatic) — mutual authentication
///   key = HKDF-SHA256(ikm = dh1 || dh2, salt = ephemeralPub, info = INFO)
///
/// Frames are IETF ChaCha20-Poly1305 boxes — chosen (over XChaCha20) because
/// Apple CryptoKit implements it natively, so Swift clients need no extra
/// dependency. Nonces are deterministic: 12 bytes = [direction byte, 0, 0, 0,
/// seq as u64 BE]. This never repeats under one key because every channel
/// open derives a fresh key (fresh ephemeral) and each direction's seq is
/// strictly monotonic — which callers MUST uphold: never seal two different
/// payloads with the same (direction, seq) on one channel. The AAD
/// additionally binds (channelId, direction, seq) so ciphertext cannot be
/// replayed across channels, directions, or positions.

const INFO = new TextEncoder().encode("codevisor-cloud-channel-v1")
export const NONCE_LENGTH = 12
export const KEY_LENGTH = 32

const DIRECTION_BYTE: Record<ChannelDirection, number> = {
  "opener-to-responder": 1,
  "responder-to-opener": 2
}

const nonceFor = (direction: ChannelDirection, seq: number): Uint8Array => {
  if (!Number.isSafeInteger(seq) || seq < 0) throw new Error("invalid seq")
  const nonce = new Uint8Array(NONCE_LENGTH)
  nonce[0] = DIRECTION_BYTE[direction]
  new DataView(nonce.buffer).setBigUint64(4, BigInt(seq))
  return nonce
}

/// Direction of a frame relative to the channel opener.
export type ChannelDirection = "opener-to-responder" | "responder-to-opener"

export interface CloudKeyPair {
  publicKey: string
  secretKey: string
}

const BASE64URL = /^[A-Za-z0-9_-]*$/

export const toBase64Url = (bytes: Uint8Array): string => {
  let binary = ""
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "")
}

export const fromBase64Url = (encoded: string): Uint8Array => {
  if (!BASE64URL.test(encoded)) throw new Error("invalid base64url input")
  const padded = encoded + "=".repeat((4 - (encoded.length % 4)) % 4)
  const binary = atob(padded.replaceAll("-", "+").replaceAll("_", "/"))
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index)
  return bytes
}

/// Generate a device's long-lived static X25519 keypair. The public key is
/// registered with the account and redistributed by the hub; peers pin it on
/// first use.
export const generateDeviceKeyPair = (): CloudKeyPair => {
  const secret = x25519.utils.randomSecretKey()
  return {
    publicKey: toBase64Url(x25519.getPublicKey(secret)),
    secretKey: toBase64Url(secret)
  }
}

const deriveKey = (dh1: Uint8Array, dh2: Uint8Array, ephemeralPublic: Uint8Array): Uint8Array => {
  const ikm = new Uint8Array(dh1.length + dh2.length)
  ikm.set(dh1, 0)
  ikm.set(dh2, dh1.length)
  return hkdf(sha256, ikm, ephemeralPublic, INFO, KEY_LENGTH)
}

const aad = (channelId: string, direction: ChannelDirection, seq: number): Uint8Array =>
  new TextEncoder().encode(`${channelId}|${direction}|${seq}`)

/// Symmetric cipher for one channel. Both peers converge on the same key and
/// use the direction tag to keep their AAD spaces disjoint.
export class ChannelCipher {
  readonly #key: Uint8Array

  constructor(key: Uint8Array) {
    if (key.length !== KEY_LENGTH) throw new Error("invalid channel key length")
    this.#key = key
  }

  /// Returns the raw box (ciphertext ‖ 16-byte tag); the deterministic nonce
  /// is never included. The box travels as a binary relay envelope payload.
  seal(
    channelId: string,
    direction: ChannelDirection,
    seq: number,
    plaintext: Uint8Array
  ): Uint8Array {
    return chacha20poly1305(
      this.#key,
      nonceFor(direction, seq),
      aad(channelId, direction, seq)
      // Callers pass views over regular ArrayBuffers; noble's stricter
      // Uint8Array<ArrayBuffer> parameter type is satisfied in practice.
    ).encrypt(plaintext as Uint8Array<ArrayBuffer>)
  }

  open(channelId: string, direction: ChannelDirection, seq: number, box: Uint8Array): Uint8Array {
    return chacha20poly1305(
      this.#key,
      nonceFor(direction, seq),
      aad(channelId, direction, seq)
    ).decrypt(box as Uint8Array<ArrayBuffer>)
  }
}

export interface OpenedChannel {
  /// Send alongside the relay `open` frame so the responder can derive the key.
  ephemeralPublicKey: string
  cipher: ChannelCipher
}

/// Opener side (typically an app connecting to a machine).
export const openChannel = (openerSecretKey: string, responderPublicKey: string): OpenedChannel => {
  const ephemeralSecret = x25519.utils.randomSecretKey()
  const ephemeralPublic = x25519.getPublicKey(ephemeralSecret)
  const responderPublic = fromBase64Url(responderPublicKey)
  const dh1 = x25519.getSharedSecret(ephemeralSecret, responderPublic)
  const dh2 = x25519.getSharedSecret(fromBase64Url(openerSecretKey), responderPublic)
  return {
    ephemeralPublicKey: toBase64Url(ephemeralPublic),
    cipher: new ChannelCipher(deriveKey(dh1, dh2, ephemeralPublic))
  }
}

/// Responder side (typically a machine accepting a channel). `openerPublicKey`
/// arrives from the hub (`peerPublicKey`) and must already be pinned/trusted
/// by the caller.
export const acceptChannel = (
  responderSecretKey: string,
  openerPublicKey: string,
  ephemeralPublicKey: string
): ChannelCipher => {
  const responderSecret = fromBase64Url(responderSecretKey)
  const ephemeralPublic = fromBase64Url(ephemeralPublicKey)
  const dh1 = x25519.getSharedSecret(responderSecret, ephemeralPublic)
  const dh2 = x25519.getSharedSecret(responderSecret, fromBase64Url(openerPublicKey))
  return new ChannelCipher(deriveKey(dh1, dh2, ephemeralPublic))
}

const utf8Encoder = new TextEncoder()
const utf8Decoder = new TextDecoder()

/// Convenience helpers for JSON channel payloads (channel opens, terminal
/// control frames). Terminal output bytes should be sealed directly instead.
export const sealJson = (
  cipher: ChannelCipher,
  channelId: string,
  direction: ChannelDirection,
  seq: number,
  value: unknown
): Uint8Array => cipher.seal(channelId, direction, seq, utf8Encoder.encode(JSON.stringify(value)))

export const openJson = (
  cipher: ChannelCipher,
  channelId: string,
  direction: ChannelDirection,
  seq: number,
  box: Uint8Array
): unknown => JSON.parse(utf8Decoder.decode(cipher.open(channelId, direction, seq, box)))
