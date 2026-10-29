import { GitDiffMode } from "./git-review.js"
import type { Endpoint } from "./openapi-endpoints.js"
import type { JsonObject } from "./openapi-schemas.js"

export const queryParameters = (endpoint: Endpoint): ReadonlyArray<JsonObject> =>
  queryParameterBuilders[endpoint]?.() ?? []

type QueryParameterBuilder = () => ReadonlyArray<JsonObject>

const queryParameterBuilders: Partial<Record<Endpoint, QueryParameterBuilder>> = {
  "GET /v1/capabilities": () => [stringQuery("cwd"), stringQuery("harnessId")],
  "GET /v1/plugins/search": () => [stringQuery("query")],
  "GET /v1/plugins/events/types": () => [stringQuery("query")],
  "GET /v1/plugins/events/subscriptions": () => [stringQuery("sessionId")],
  "GET /v1/agents": () => [
    stringQuery("state"),
    stringQuery("project"),
    stringQuery("label"),
    stringQuery("parentAgentId")
  ],
  "GET /v1/agents/:id/search": () => [
    stringQuery("query"),
    stringQuery("kinds"),
    stringQuery("tool"),
    stringQuery("last"),
    stringQuery("next")
  ],
  "GET /v1/sandboxes/:id/log": () => [stringQuery("last")],
  "DELETE /v1/sandbox-accounts/:id": () => [
    { name: "cascade", in: "query", schema: { type: "string", enum: ["true"] } }
  ],
  "GET /v1/sessions/:id/transcript": () => transcriptPageQuery(),
  "GET /v1/sessions/:id/transcript/:itemId/details": () => transcriptDetailsQuery(),
  "GET /v1/sessions/:id/transcript/:itemId/body": () => transcriptBodyQuery(),
  "GET /v1/fs/git/diff": () => gitDiffQuery(),
  "GET /v1/fs/git/refs": () => [requiredStringQuery("path")],
  "GET /v1/fs/git/pull-request": () => [requiredStringQuery("path")],
  "GET /v1/workspaces/:workspaceId/git": () => workspaceGitQuery(),
  "GET /v1/workspaces/:workspaceId/photos": () => workspaceMediaPageQuery(),
  "GET /v1/workspaces/:workspaceId/media": () => workspaceMediaPageQuery(),
  "GET /v1/workspaces/:workspaceId/links": () => workspaceMediaPageQuery(),
  "GET /v1/files/:id": () => [
    { name: "preview", in: "query", schema: { type: "string", enum: ["1"] } }
  ],
  "POST /v1/files": () => [
    { name: "name", in: "query", schema: { type: "string", default: "attachment" } }
  ],
  "GET /v1/terminals/:id/socket": () => [sequenceQuery("lastOutputSeq")],
  "GET /v1/events/socket": () => [sequenceQuery("since")],
  "GET /v1/sessions/:id/events/socket": () => [sequenceQuery("since")],
  "GET /v1/events": () => [sequenceQuery("since")]
}

const transcriptPageQuery = (): ReadonlyArray<JsonObject> => [
  {
    name: "before",
    in: "query",
    description: "Opaque nextBefore or nextAfter cursor from a transcript page.",
    schema: { type: "string" }
  },
  {
    name: "limit",
    in: "query",
    schema: { type: "integer", minimum: 1, maximum: 64, default: 32 }
  }
]

const transcriptDetailsQuery = (): ReadonlyArray<JsonObject> => [
  {
    name: "after",
    in: "query",
    description: "Opaque nextAfter or previousBefore cursor, or latest to open the newest details.",
    schema: { type: "string" }
  }
]

const transcriptBodyQuery = (): ReadonlyArray<JsonObject> => [
  requiredStringQuery("key"),
  requiredStringQuery("field"),
  { name: "position", in: "query", schema: { type: "integer", minimum: 0, default: 0 } }
]

const gitDiffQuery = (): ReadonlyArray<JsonObject> => [
  requiredStringQuery("path"),
  {
    name: "mode",
    in: "query",
    required: true,
    schema: { type: "string", enum: [...GitDiffMode.literals] }
  },
  {
    name: "base",
    in: "query",
    description: "Branch mode's base ref; defaults to the repository's default branch.",
    schema: { type: "string" }
  },
  {
    name: "revision",
    in: "query",
    description: "A previous response's revision; when still current, files are not resent.",
    schema: { type: "string" }
  }
]

const workspaceGitQuery = (): ReadonlyArray<JsonObject> => [
  {
    name: "pullRequest",
    in: "query",
    description: "Also look up the branch's GitHub pull request.",
    schema: { type: "boolean" }
  }
]

const workspaceMediaPageQuery = (): ReadonlyArray<JsonObject> => [
  {
    name: "before",
    in: "query",
    description: "Opaque nextBefore cursor from a previous page.",
    schema: { type: "string" }
  },
  { name: "limit", in: "query", schema: { type: "integer", minimum: 1, maximum: 200 } }
]

const stringQuery = (name: string): JsonObject => ({
  name,
  in: "query",
  schema: { type: "string" }
})

const requiredStringQuery = (name: string): JsonObject => ({
  name,
  in: "query",
  required: true,
  schema: { type: "string" }
})

const sequenceQuery = (name: string): JsonObject => ({
  name,
  in: "query",
  schema: { type: "integer", minimum: 0 }
})
