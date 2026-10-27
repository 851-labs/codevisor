import type { HubInboxItem } from "@codevisor/api"
import { acceptChannel, fromBase64Url, openJson } from "@codevisor/cloud-crypto"

export const openInboxItem = (secretKey: string, frame: HubInboxItem): unknown =>
  openJson(
    acceptChannel(secretKey, frame.sender, frame.ephemeralKey),
    frame.itemId,
    "opener-to-responder",
    0,
    fromBase64Url(frame.sealed)
  )
