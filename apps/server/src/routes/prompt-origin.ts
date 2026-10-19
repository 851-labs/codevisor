import type { PromptOrigin } from "@codevisor/api"

export const transcriptOrigin = (
  origin: PromptOrigin | undefined
): { readonly origin?: "event" } => (origin === "system" ? { origin: "event" } : {})
