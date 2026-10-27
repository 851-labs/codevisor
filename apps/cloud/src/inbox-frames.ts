import { generateDeviceKeyPair, openChannel, sealJson, toBase64Url } from "@codevisor/cloud-crypto"
import { z } from "zod"

export type InboxItemKind = "webhook" | "oauth"

export interface InboxItemFrame {
  readonly t: "inbox-item"
  readonly itemId: string
  readonly kind: InboxItemKind
  readonly sender: string
  readonly ephemeralKey: string
  readonly sealed: string
}

export interface InboxRequest {
  readonly method: string
  readonly headers: Readonly<Record<string, string>>
  readonly body: string
  readonly receivedAt: string
}

export interface WebhookItem extends InboxRequest {
  readonly itemId: string
  readonly inboxId: string
}

export interface OAuthCallbackItem {
  readonly flowId: string
  readonly state: string
  readonly code?: string
  readonly error?: string
}

export const INBOX_SEAL_DIRECTION = "opener-to-responder"
export const INBOX_SEAL_SEQ = 0
export const MAX_ACK_BATCH = 500

export const sealInboxItem = (
  devicePublicKey: string,
  itemId: string,
  kind: InboxItemKind,
  payload: WebhookItem | OAuthCallbackItem
): InboxItemFrame => {
  const sender = generateDeviceKeyPair()
  const channel = openChannel(sender.secretKey, devicePublicKey)
  const sealed = sealJson(channel.cipher, itemId, INBOX_SEAL_DIRECTION, INBOX_SEAL_SEQ, payload)
  return {
    t: "inbox-item",
    itemId,
    kind,
    sender: sender.publicKey,
    ephemeralKey: channel.ephemeralPublicKey,
    sealed: toBase64Url(sealed)
  }
}

export const inboxAckItemIds = (message: string): string[] | undefined => {
  const parsed = InboxAckFrame.safeParse(parseJson(message))
  return parsed.success ? parsed.data.itemIds : undefined
}

const InboxAckFrame = z.object({
  t: z.literal("inbox-ack"),
  itemIds: z.array(z.string().min(1).max(100)).max(MAX_ACK_BATCH)
})

const parseJson = (message: string): unknown => {
  try {
    return JSON.parse(message)
  } catch {
    return undefined
  }
}
