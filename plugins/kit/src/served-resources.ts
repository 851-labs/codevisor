import type { Server } from "@modelcontextprotocol/sdk/server/index.js"
import {
  ListResourcesRequestSchema,
  ReadResourceRequestSchema
} from "@modelcontextprotocol/sdk/types.js"

import { resourceNotFoundError } from "./plugin-protocol.js"

export interface ServedResource {
  uri: string
  name: string
  mimeType: string
  text: string
}

export const registerResources = (
  server: Server,
  resources: ReadonlyArray<ServedResource>
): void => {
  server.setRequestHandler(ListResourcesRequestSchema, () => ({
    resources: resources.map(listing)
  }))
  server.setRequestHandler(ReadResourceRequestSchema, (request) => ({
    resultType: "complete",
    contents: [contents(resourceAt(resources, request.params.uri))]
  }))
}

const listing = (resource: ServedResource) => ({
  uri: resource.uri,
  name: resource.name,
  mimeType: resource.mimeType
})

const contents = (resource: ServedResource) => ({
  uri: resource.uri,
  mimeType: resource.mimeType,
  text: resource.text
})

const resourceAt = (resources: ReadonlyArray<ServedResource>, uri: string): ServedResource => {
  const resource = resources.find((candidate) => candidate.uri === uri)
  if (resource === undefined) throw resourceNotFoundError(uri)

  return resource
}
