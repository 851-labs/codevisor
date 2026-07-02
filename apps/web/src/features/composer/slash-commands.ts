// Slash-command query parsing, ported from ComposerView.swift
// (slashQuery/slashMatches): the query is the first line's leading "/token"
// with no spaces; matches are exact-name hits first, then prefix hits.
export interface SlashCommand {
  name: string
  description: string
  hint?: string
}

export function slashQueryFrom(text: string): string | undefined {
  if (!text.startsWith("/")) return undefined
  const firstLine = text.split("\n", 1)[0] ?? ""
  const token = firstLine.slice(1)
  if (token.includes(" ")) return undefined
  return token.toLowerCase()
}

export function slashMatchesFor(
  commands: readonly SlashCommand[],
  query: string | undefined
): SlashCommand[] {
  if (query == null || commands.length === 0) return []
  if (query === "") return [...commands]
  const exact = commands.filter((command) => command.name.toLowerCase() === query)
  const prefixed = commands.filter(
    (command) =>
      command.name.toLowerCase().startsWith(query) &&
      !exact.some((match) => match.name === command.name)
  )
  return [...exact, ...prefixed]
}
