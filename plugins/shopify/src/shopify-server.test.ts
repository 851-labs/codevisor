import { toolText } from "@codevisor/plugin-kit/test-support"
import { describe, expect, it } from "vitest"

import {
  cliFailure,
  cliJson,
  connectShopify,
  fakeShopifyCli,
  shopifyCommand
} from "./shopify-test-support.js"

const store = "acme-goods.myshopify.com"
const jsonFlags = ["--json", "--no-color"]

describe("Shopify sign-in", () => {
  it("runs shopify store auth for the store the user typed and names the account", async () => {
    const fake = fakeShopifyCli()
    fake.respond(
      cliJson({ store, scopes: ["read_products"], associatedUser: { email: "owner@acme.test" } })
    )
    const shopify = await connectShopify(fake)

    const signedIn = await shopify.signIn({ store: "https://Acme-Goods.myshopify.com/admin" }, [
      "read_products",
      "write_products"
    ])

    expect(signedIn).toEqual({ label: store, identity: "owner@acme.test" })
    expect(fake.calls).toEqual([
      {
        command: shopifyCommand.command,
        args: [
          "store",
          "auth",
          "--store",
          store,
          "--scopes",
          "read_products,write_products",
          ...jsonFlags
        ]
      }
    ])
  })

  it("refuses an address that isn't a myshopify.com store without running the CLI", async () => {
    const fake = fakeShopifyCli()
    const shopify = await connectShopify(fake)

    await expect(shopify.signIn({ store: "acme.com" }, ["read_products"])).rejects.toThrow(
      "isn't a myshopify.com address"
    )
    expect(fake.calls).toEqual([])
  })

  it("reports why the CLI couldn't sign in", async () => {
    const fake = fakeShopifyCli()
    fake.respond(cliFailure({ message: "Timed out waiting for OAuth callback." }))
    const shopify = await connectShopify(fake)

    await expect(shopify.signIn({ store: "acme-goods" }, ["read_products"])).rejects.toThrow(
      "Timed out waiting for OAuth callback."
    )
  })
})

describe("Shopify tools", () => {
  it("runs queries and ShopifyQL read-only against the account's store", async () => {
    const fake = fakeShopifyCli()
    fake.respond(cliJson({ data: { shop: { name: "Acme Goods" } } }))
    fake.respond(cliJson({ data: { shopifyqlQuery: { parseErrors: [] } } }))
    const shopify = await connectShopify(fake)

    const queried = await shopify.callTool("run_query", { query: "query { shop { name } }" }, store)
    await shopify.callTool(
      "run_analytics",
      { query: "FROM sales SHOW total_sales SINCE -7d" },
      store
    )

    expect(JSON.parse(toolText(queried))).toEqual({ store, data: { shop: { name: "Acme Goods" } } })
    expect(fake.calls.map((call) => call.args)).toEqual([
      ["store", "execute", "--store", store, "--query", "query { shop { name } }", ...jsonFlags],
      [
        "store",
        "execute",
        "--store",
        store,
        "--query",
        expect.stringContaining("shopifyqlQuery(query: $query)"),
        "--variables",
        JSON.stringify({ query: "FROM sales SHOW total_sales SINCE -7d" }),
        ...jsonFlags
      ]
    ])
  })

  it("changes the store only once the agent confirms the user approved", async () => {
    const fake = fakeShopifyCli()
    fake.respond(cliJson({ data: { productUpdate: { userErrors: [] } } }))
    const shopify = await connectShopify(fake)
    const mutation =
      "mutation($id: ID!) { productUpdate(product: { id: $id, status: DRAFT }) { userErrors { message } } }"
    const variables = { id: "gid://shopify/Product/1" }

    const unconfirmed = await shopify.callTool(
      "run_mutation",
      { mutation, variables, confirm: false },
      store
    )
    const callsBeforeApproval = fake.calls.length
    const confirmed = await shopify.callTool(
      "run_mutation",
      { mutation, variables, confirm: true },
      store
    )

    expect(unconfirmed).toMatchObject({ isError: true })
    expect(toolText(unconfirmed)).toContain("explicit approval")
    expect(callsBeforeApproval).toBe(0)
    expect(confirmed).not.toHaveProperty("isError")
    expect(fake.calls[0]?.args).toEqual([
      "store",
      "execute",
      "--store",
      store,
      "--query",
      mutation,
      "--variables",
      JSON.stringify(variables),
      "--allow-mutations",
      ...jsonFlags
    ])
  })

  it("asks for sign-in when the store isn't signed in on this machine or no store is chosen", async () => {
    const fake = fakeShopifyCli()
    fake.respond(
      cliFailure({
        message: `No stored app authentication found for ${store}.`,
        nextSteps: ["Run shopify store auth --store …"]
      })
    )
    const shopify = await connectShopify(fake)

    const unsignedStore = await shopify.callTool(
      "run_query",
      { query: "query { shop { name } }" },
      store
    )
    const noStore = await shopify.callTool("run_query", { query: "query { shop { name } }" })

    expect(toolText(unsignedStore)).toBe(
      `Shopify isn't signed in to ${store} on this machine. Ask the user to sign in from Settings › Plugins › Shopify.`
    )
    expect(toolText(noStore)).toContain("A signed-in Shopify store is required")
  })

  it("passes on Shopify's error and the CLI's hint", async () => {
    const fake = fakeShopifyCli()
    fake.respond(
      cliFailure({
        message: "GraphQL operation failed.",
        tryMessage: "Check the access scopes."
      })
    )
    fake.respond({ code: 1, stdout: "", stderr: "node: bad option" })
    const shopify = await connectShopify(fake)

    const graphql = await shopify.callTool("run_query", { query: "query { orders { id } }" }, store)
    const crashed = await shopify.callTool("run_query", { query: "query { shop { id } }" }, store)

    expect(toolText(graphql)).toBe("GraphQL operation failed. Check the access scopes.")
    expect(toolText(crashed)).toBe("The Shopify CLI failed (exit 1): node: bad option")
  })
})
