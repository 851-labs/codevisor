import { makeOpenApiDocument } from "@codevisor/api"
import type { OpenAPIV3_2 } from "fumadocs-openapi"
import { createOpenAPI } from "fumadocs-openapi/server"

export const openapi = createOpenAPI({
  input: {
    codevisor: () =>
      // oxlint-disable-next-line typescript/no-unsafe-type-assertion
      makeOpenApiDocument("v1-experimental") as unknown as OpenAPIV3_2.Document
  }
})
