import { makeOpenApiDocument } from "@herdman/api"
import { createOpenAPI } from "fumadocs-openapi/server"

export const openapi = createOpenAPI({
  input: {
    herdman: () => makeOpenApiDocument("v1-experimental") as never
  }
})
