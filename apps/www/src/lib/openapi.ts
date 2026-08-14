// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
import { makeOpenApiDocument } from "@codevisor/api"
import { createOpenAPI } from "fumadocs-openapi/server"

export const openapi = createOpenAPI({
  input: {
    codevisor: () => makeOpenApiDocument("v1-experimental") as never
  }
})
