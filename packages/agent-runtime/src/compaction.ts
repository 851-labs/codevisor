export const COMPACT_COMMAND = "compact"

export interface CompactRequest {
  readonly instructions?: string
}

export const compactRequest = (text: string): CompactRequest | undefined => {
  const match = compactPrompt.exec(text.trim())
  if (match === null) return undefined

  const instructions = match[1]?.trim() ?? ""
  return instructions === "" ? {} : { instructions }
}

export const isCompactPrompt = (text: string): boolean => compactRequest(text) !== undefined

const compactPrompt = /^\/compact(?:\s+([\s\S]*))?$/
