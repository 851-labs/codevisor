// Shared internals for the split Codex provider modules.

export const firstLine = (text: string): string => text.split("\n")[0]?.slice(0, 80) ?? ""

export const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null
