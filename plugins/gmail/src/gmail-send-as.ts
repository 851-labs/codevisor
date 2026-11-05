import { formatAddress, parseAddresses } from "./gmail-addresses.js"
import type { GmailApi, GmailMessage, GmailSendAs } from "./gmail-api.js"
import { GmailToolError } from "./gmail-labels.js"
import { headerOf } from "./gmail-message.js"

export interface SendAsAddress {
  email: string
  name: string
  isDefault: boolean
  isPrimary: boolean
}

export const sendAsAddresses = async (api: GmailApi): Promise<Array<SendAsAddress>> =>
  (await api.sendAs()).filter(usable).map(sendAsAddress)

export const requestedFrom = async (
  api: GmailApi,
  from: string | undefined
): Promise<string | undefined> => {
  if (from === undefined) return undefined

  const addresses = await sendAsAddresses(api)
  return fromHeader(addresses, chosenSendAs(addresses, from))
}

export const replySendAs = (
  addresses: ReadonlyArray<SendAsAddress>,
  original: GmailMessage,
  from: string | undefined
): SendAsAddress | undefined => {
  if (from !== undefined) return chosenSendAs(addresses, from)

  return addressesOn(original)
    .map((email) => addresses.find((address) => address.email === email))
    .find((address) => address !== undefined)
}

export const fromHeader = (
  addresses: ReadonlyArray<SendAsAddress>,
  sender: SendAsAddress | undefined
): string => {
  if (sender === undefined || sender.isDefault) return ""

  return formatAddress({ email: sender.email, name: sender.name || primaryName(addresses) })
}

const chosenSendAs = (addresses: ReadonlyArray<SendAsAddress>, from: string): SendAsAddress => {
  const email = parseAddresses(from)[0]?.email
  const sender = addresses.find((address) => address.email === email)
  if (sender === undefined) throw new GmailToolError(unknownSendAs(from))

  return sender
}

const unknownSendAs = (from: string): string =>
  `${from} isn't a send-as address on this account. Call list_send_as to see the addresses it can send from.`

const addressesOn = (original: GmailMessage): Array<string> =>
  addressHeaders
    .flatMap((name) => parseAddresses(headerOf(original, name)))
    .map((address) => address.email)

const addressHeaders = ["From", "To", "Cc", "Delivered-To"]

const primaryName = (addresses: ReadonlyArray<SendAsAddress>): string =>
  addresses.find((address) => address.isPrimary)?.name ?? ""

const usable = (sendAs: GmailSendAs): boolean => sendAs.verificationStatus !== "pending"

const sendAsAddress = (sendAs: GmailSendAs): SendAsAddress => ({
  email: sendAs.sendAsEmail.toLowerCase(),
  name: sendAs.displayName,
  isDefault: sendAs.isDefault,
  isPrimary: sendAs.isPrimary
})
