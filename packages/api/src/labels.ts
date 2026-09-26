import { Schema } from "effect"

/// Free-form key/value labels an orchestrating agent attaches to sessions and
/// workspaces so it can find its work again (for example after compaction).
export const Labels = Schema.Record(Schema.String, Schema.String)
export type Labels = typeof Labels.Type
