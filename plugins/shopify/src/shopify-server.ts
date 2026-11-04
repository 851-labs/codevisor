import {
  accountSignInRequest,
  errorResult,
  registerResources,
  registerSkills,
  skillCatalog,
  skillsExtension
} from "@codevisor/plugin-kit"
import { Server } from "@modelcontextprotocol/sdk/server/index.js"
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js"

import { missingShopifyStore, storeOfAccount } from "./shopify-account.js"
import type { ShopifyCli } from "./shopify-cli.js"
import { shopifySkill } from "./shopify-skill.js"
import { storeDomainOf } from "./shopify-store.js"
import { shopifyTools } from "./shopify-tool-catalog.js"
import { runShopifyTool } from "./shopify-tools.js"

export const shopifyCapabilities = {
  tools: {},
  resources: {},
  extensions: { [skillsExtension]: {} }
}

export const createShopifyServer = (cli: ShopifyCli): Server => {
  const server = new Server(
    { name: "shopify", version: "1.0.0" },
    { capabilities: shopifyCapabilities }
  )

  registerTools(server, cli)
  registerSignIn(server, cli)
  registerResources(server, skills.resources)
  registerSkills(server, skills)
  return server
}

const registerTools = (server: Server, cli: ShopifyCli): void => {
  server.setRequestHandler(ListToolsRequestSchema, () => ({ tools: [...shopifyTools] }))
  server.setRequestHandler(CallToolRequestSchema, (request, extra) => {
    const store = storeOfAccount(extra._meta)
    if (store === undefined) return errorResult(missingShopifyStore)

    return runShopifyTool(request.params.name, request.params.arguments ?? {}, { cli, store })
  })
}

const registerSignIn = (server: Server, cli: ShopifyCli): void => {
  server.setRequestHandler(accountSignInRequest, async (request) => {
    const store = storeDomainOf(request.params.values.store)
    const session = await cli.signIn(store, request.params.scopes)
    return {
      label: session.store,
      ...(session.email === undefined ? {} : { identity: session.email })
    }
  })
}

const skills = skillCatalog([shopifySkill])
