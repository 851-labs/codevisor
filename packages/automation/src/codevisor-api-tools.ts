import { codevisorServerApiTools } from "./codevisor-api-tools-server.js"
import { codevisorSessionApiTools } from "./codevisor-api-tools-sessions.js"
import { codevisorExtensionApiTools } from "./codevisor-api-tools-extensions.js"
import { codevisorHarnessApiTools } from "./codevisor-api-tools-harnesses.js"
import type { CodevisorApiToolSpec } from "./codevisor-api-tool-spec.js"

export { objectSchema } from "./codevisor-api-tool-spec.js"
export type {
  CodevisorApiToolSpec,
  HttpMethod,
  JsonSchema,
  QueryParameter
} from "./codevisor-api-tool-spec.js"

/// The server-only Codevisor control plane. Every entry delegates to the same
/// authenticated /v1 route used by native clients, so validation, durable
/// events, idempotency, and lifecycle side effects have one implementation.
export const CODEVISOR_API_TOOLS: ReadonlyArray<CodevisorApiToolSpec> = [
  ...codevisorServerApiTools,
  ...codevisorSessionApiTools,
  ...codevisorExtensionApiTools,
  ...codevisorHarnessApiTools
]
