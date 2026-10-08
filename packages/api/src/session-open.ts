import { Schema } from "effect"

import { CreateProjectRequest } from "./projects.js"
import {
  CreateSessionRequest,
  SessionSummary,
  TranscriptPage,
  UpdateSessionRequest
} from "./sessions.js"

/// One-round-trip chat open: ensure the project and session records exist and
/// return the first transcript page together. Replaces the discrete
/// listProjects → createProject → listSessions → create/update → transcript
/// sequence, whose 3–4 serial round-trips delayed the first transcript paint
/// on every chat open (whole seconds over high-latency remote links).
export const OpenSessionRequest = Schema.Struct({
  /// Create-if-missing. An existing project is deliberately never updated
  /// from this snapshot: it was taken when the client's draft was created,
  /// and pushing it on open could revert changes made in the meantime
  /// (e.g. un-archiving an archived project).
  project: Schema.optional(CreateProjectRequest),
  /// Used only when the session does not exist yet. Its `id`, when present,
  /// must match the id in the path.
  session: CreateSessionRequest,
  /// Applied when the session already exists — the same fields the discrete
  /// PATCH used to send while opening.
  update: Schema.optional(UpdateSessionRequest),
  /// First transcript page size (same default as GET …/transcript).
  transcriptLimit: Schema.optional(Schema.Number)
})
export type OpenSessionRequest = typeof OpenSessionRequest.Type

export const OpenSessionResponse = Schema.Struct({
  session: SessionSummary,
  transcript: TranscriptPage,
  runtime: Schema.Unknown
})
export type OpenSessionResponse = typeof OpenSessionResponse.Type
