import type { HubInboxItem } from "@codevisor/api"
import { generateDeviceKeyPair, openChannel, sealJson, toBase64Url } from "@codevisor/cloud-crypto"

export const inboxDevice = generateDeviceKeyPair()

const sender = generateDeviceKeyPair()
const channel = openChannel(sender.secretKey, inboxDevice.publicKey)

export const sealedInboxItem = (
  itemId: string,
  kind: HubInboxItem["kind"],
  payload: unknown
): HubInboxItem => ({
  t: "inbox-item",
  itemId,
  kind,
  sender: sender.publicKey,
  ephemeralKey: channel.ephemeralPublicKey,
  sealed: toBase64Url(sealJson(channel.cipher, itemId, "opener-to-responder", 0, payload))
})
