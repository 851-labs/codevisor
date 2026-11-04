import type { Tool } from "@modelcontextprotocol/sdk/types.js"

const readOnly = { readOnlyHint: true, openWorldHint: false }
const changesStore = { readOnlyHint: false, destructiveHint: true, openWorldHint: true }

const text = (description: string) => ({ type: "string", description })

const variables = {
  type: "object",
  additionalProperties: true,
  description: "GraphQL variables, as a JSON object."
}

export const shopifyTools: ReadonlyArray<Tool> = [
  {
    name: "run_query",
    description:
      "Run a read-only Admin GraphQL query against the signed-in store: products, variants, inventory, collections, orders, customers, discounts, themes, metafields and more. Mutations are refused here.",
    inputSchema: {
      type: "object",
      properties: {
        query: text("An Admin GraphQL query, such as query { shop { name } }."),
        variables
      },
      required: ["query"]
    },
    annotations: readOnly
  },
  {
    name: "run_analytics",
    description:
      "Run a read-only ShopifyQL analytics query, such as FROM sales SHOW total_sales SINCE -30d. Returns columns, rows and any parse errors.",
    inputSchema: {
      type: "object",
      properties: { query: text("A ShopifyQL query that starts with FROM … SHOW ….") },
      required: ["query"]
    },
    annotations: readOnly
  },
  {
    name: "run_mutation",
    description:
      "Change the store with an Admin GraphQL mutation, only after the user approves the exact change.",
    inputSchema: {
      type: "object",
      properties: {
        mutation: text("An Admin GraphQL mutation."),
        variables,
        confirm: {
          type: "boolean",
          description:
            "Set true only after showing the user exactly what will change in which store and getting their explicit approval."
        }
      },
      required: ["mutation", "confirm"]
    },
    annotations: changesStore
  }
]
