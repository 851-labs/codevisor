import { accountFromMeta } from "@codevisor/plugin-kit"

import { storeDomainOf } from "./shopify-store.js"

export const storeOfAccount = (meta: Record<string, unknown> | undefined): string | undefined => {
  const store = accountFromMeta(meta)?.fields.store
  if (store === undefined) return undefined

  try {
    return storeDomainOf(store)
  } catch {
    return undefined
  }
}

export const missingShopifyStore =
  "A signed-in Shopify store is required. Sign in from Settings › Plugins › Shopify."
