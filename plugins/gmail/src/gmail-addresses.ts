export interface MailAddress {
  email: string
  name: string
}

export const parseAddresses = (value: string): Array<MailAddress> =>
  (value.match(addressPattern) ?? [])
    .map((part) => part.trim())
    .filter((part) => part !== "")
    .map(parseAddress)

export const formatAddress = (address: MailAddress): string => {
  if (address.name === "") return address.email

  return `${quotedName(address.name)} <${address.email}>`
}

export const sameAddress = (left: MailAddress, right: string | undefined): boolean =>
  right !== undefined && left.email === right.toLowerCase()

export const withoutDuplicates = (addresses: ReadonlyArray<MailAddress>): Array<MailAddress> =>
  addresses.filter(
    (address, index) => addresses.findIndex((other) => other.email === address.email) === index
  )

const addressPattern = /(?:"[^"]*"|<[^>]*>|[^,])+/g
const angleAddress = /^(.*?)\s*<([^>]*)>$/
const specialNameCharacters = /[",;:<>@()[\]\\]/

const parseAddress = (part: string): MailAddress => {
  const match = angleAddress.exec(part)
  if (match === null) return { email: part.toLowerCase(), name: "" }

  return {
    email: String(match[2]).trim().toLowerCase(),
    name: String(match[1]).replaceAll('"', "").trim()
  }
}

const quotedName = (name: string): string => {
  if (!specialNameCharacters.test(name)) return name

  return `"${name.replaceAll(/["\\]/g, "")}"`
}
