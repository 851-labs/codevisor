import { chacha20poly1305 } from "@noble/ciphers/chacha.js"
import { x25519 } from "@noble/curves/ed25519.js"
import { hkdf } from "@noble/hashes/hkdf.js"
import { sha256 } from "@noble/hashes/sha2.js"

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

export class ChannelCipher {
  readonly #key: Uint8Array

  constructor(key: Uint8Array) {
    if (key.length !== KEY_LENGTH) throw new Error("invalid channel key length")
    this.#key = key
  }

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
  ephemeralPublicKey: string
  cipher: ChannelCipher
}

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
