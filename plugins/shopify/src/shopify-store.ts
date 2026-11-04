export class ShopifyToolError extends Error {}

export const storeDomainOf = (value: unknown): string => {
  if (typeof value !== "string") throw new ShopifyToolError(missingStore)
  const host = hostOf(value.trim().toLowerCase())
  const domain = host.includes(".") ? host : `${host}${myshopifySuffix}`
  if (!isStoreDomain(domain)) throw new ShopifyToolError(notAStoreDomain(value))

  return domain
}

const hostOf = (value: string): string => {
  const withoutScheme = value.replace(/^https?:\/\//, "")
  return withoutScheme.split("/")[0] ?? ""
}

const isStoreDomain = (domain: string): boolean =>
  domain.endsWith(myshopifySuffix) && storeHandle.test(domain.slice(0, -myshopifySuffix.length))

const myshopifySuffix = ".myshopify.com"
const storeHandle = /^[a-z0-9][a-z0-9-]*$/

const missingStore = "Enter your store's myshopify.com address, like my-store.myshopify.com."

const notAStoreDomain = (value: string): string =>
  `${value} isn't a myshopify.com address. Use the one in Shopify admin › Settings › Domains, like my-store.myshopify.com.`
