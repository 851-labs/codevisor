import {
  formatAddress,
  parseAddresses,
  withoutDuplicates,
  type MailAddress
} from "./gmail-addresses.js"
import type { GmailMessage } from "./gmail-api.js"
import { plainTextBody } from "./gmail-body.js"
import type { MessageFields } from "./gmail-compose.js"
import { headerOf, senderOf } from "./gmail-message.js"

export interface Recipients {
  to?: string | undefined
  cc?: string | undefined
  bcc?: string | undefined
  subject?: string | undefined
}

export interface NewMessage extends Recipients {
  body: string
}

export interface ReplyOptions {
  replyAll: boolean
  me: ReadonlyArray<string>
  from: string
}

export interface DraftChanges extends Recipients {
  body?: string | undefined
  from?: string | undefined
}

export const newMessageFields = (input: NewMessage, from = ""): MessageFields => ({
  from,
  to: input.to ?? "",
  cc: input.cc ?? "",
  bcc: input.bcc ?? "",
  subject: input.subject ?? "",
  body: input.body,
  inReplyTo: "",
  references: "",
  threadId: undefined
})

export const replyFields = (
  original: GmailMessage,
  input: NewMessage,
  options: ReplyOptions
): MessageFields => {
  const recipients = replyRecipients(original, options)
  const messageId = headerOf(original, "Message-ID")
  return {
    from: options.from,
    to: input.to ?? addressList(recipients.to),
    cc: input.cc ?? addressList(recipients.cc),
    bcc: input.bcc ?? "",
    subject: input.subject ?? replySubject(headerOf(original, "Subject")),
    body: input.body,
    inReplyTo: messageId,
    references: [headerOf(original, "References"), messageId].filter(present).join(" "),
    threadId: original.threadId
  }
}

export const updatedDraftFields = (existing: GmailMessage, input: DraftChanges): MessageFields => ({
  from: input.from ?? headerOf(existing, "From"),
  to: input.to ?? headerOf(existing, "To"),
  cc: input.cc ?? headerOf(existing, "Cc"),
  bcc: input.bcc ?? headerOf(existing, "Bcc"),
  subject: input.subject ?? headerOf(existing, "Subject"),
  body: input.body ?? plainTextBody(existing.payload),
  inReplyTo: headerOf(existing, "In-Reply-To"),
  references: headerOf(existing, "References"),
  threadId: existing.threadId
})

interface ReplyRecipients {
  to: Array<MailAddress>
  cc: Array<MailAddress>
}

const replyRecipients = (original: GmailMessage, options: ReplyOptions): ReplyRecipients => {
  const to = primaryRecipients(original, options.me)
  if (!options.replyAll) return { to, cc: [] }

  const everyone = parseAddresses(`${headerOf(original, "To")},${headerOf(original, "Cc")}`)
  const others = everyone.filter((address) => copiedOnReply(address, to, options.me))
  return { to, cc: withoutDuplicates(others) }
}

const copiedOnReply = (
  address: MailAddress,
  to: ReadonlyArray<MailAddress>,
  me: ReadonlyArray<string>
): boolean => !isMine(address, me) && !to.some((same) => same.email === address.email)

const primaryRecipients = (
  original: GmailMessage,
  me: ReadonlyArray<string>
): Array<MailAddress> => {
  const sender = senderOf(original)
  if (isMine(sender, me)) return parseAddresses(headerOf(original, "To"))

  const replyTo = parseAddresses(headerOf(original, "Reply-To"))
  if (replyTo.length > 0) return replyTo

  return [sender]
}

const isMine = (address: MailAddress, me: ReadonlyArray<string>): boolean =>
  me.includes(address.email)

const addressList = (addresses: ReadonlyArray<MailAddress>): string =>
  addresses.map(formatAddress).join(", ")

const replySubject = (subject: string): string => {
  if (replyPrefix.test(subject)) return subject

  return `Re: ${subject}`
}

const present = (value: string): boolean => value !== ""

const replyPrefix = /^re:/i
