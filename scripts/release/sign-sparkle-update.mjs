#!/usr/bin/env node
import {
  createPrivateKey,
  createPublicKey,
  sign as createSignature,
  verify as verifySignature
} from "node:crypto"
import { readFileSync } from "node:fs"

const ed25519PKCS8Prefix = Buffer.from("302e020100300506032b657004220420", "hex")
const ed25519SPKIPrefix = Buffer.from("302a300506032b6570032100", "hex")

const decodeSeed = (secret) => {
  const normalized = secret.trim()
  const seed = Buffer.from(normalized, "base64")
  if (
    seed.length !== 32 ||
    seed.toString("base64").replaceAll("=", "") !== normalized.replaceAll("=", "")
  ) {
    throw new Error("Sparkle private key must be a base64-encoded 32-byte Ed25519 seed")
  }
  return seed
}

export const signSparkleUpdate = (contents, secret, expectedPublicKey) => {
  const privateKey = createPrivateKey({
    key: Buffer.concat([ed25519PKCS8Prefix, decodeSeed(secret)]),
    format: "der",
    type: "pkcs8"
  })
  const publicDER = createPublicKey(privateKey).export({ format: "der", type: "spki" })
  if (!publicDER.subarray(0, ed25519SPKIPrefix.length).equals(ed25519SPKIPrefix)) {
    throw new Error("Unable to derive the Sparkle Ed25519 public key")
  }
  const publicKey = publicDER.subarray(ed25519SPKIPrefix.length)
  if (publicKey.toString("base64") !== expectedPublicKey) {
    throw new Error("Sparkle private key does not match the app's pinned public key")
  }

  const signature = createSignature(null, contents, privateKey)
  if (!verifySignature(null, contents, createPublicKey(privateKey), signature)) {
    throw new Error("Sparkle signature verification failed")
  }
  return signature.toString("base64")
}

if (process.argv[1] === import.meta.filename) {
  const [, , path, publicKey] = process.argv
  const privateKey = process.env.SPARKLE_PRIVATE_KEY
  if (!path || !publicKey || !privateKey) {
    console.error(
      "usage: SPARKLE_PRIVATE_KEY=... sign-sparkle-update.mjs <archive-path> <public-key>"
    )
    process.exit(1)
  }
  console.log(signSparkleUpdate(readFileSync(path), privateKey, publicKey))
}
