import { homedir } from "node:os"
import { extname, isAbsolute, resolve } from "node:path"
import { fileURLToPath } from "node:url"

export interface MarkdownFileReference {
  readonly start: number
  readonly end: number
  readonly target: string
  readonly embedded: boolean
}

const escaped = (source: string, index: number): boolean => {
  let count = 0
  while (index > 0 && source[--index] === "\\") count++
  return count % 2 === 1
}

// Keep code examples literal. Offsets always refer to the original Markdown.
export const markdownFileReferences = (source: string): ReadonlyArray<MarkdownFileReference> => {
  const code = new Uint8Array(source.length)
  let offset = 0
  let fence: { character: string; length: number } | undefined
  for (const line of source.match(/[^\n]*\n|[^\n]+$/g) ?? []) {
    const content = line.replace(/^(?: {0,3}> ?)+/, "")
    const run = /^ {0,3}(`{3,}|~{3,})(.*)/.exec(content)
    if (fence !== undefined) {
      code.fill(1, offset, offset + line.length)
      if (run?.[1]?.[0] === fence.character && run[1].length >= fence.length && !run[2]?.trim())
        fence = undefined
    } else if (run !== null && !(run[1]![0] === "`" && run[2]!.includes("`"))) {
      fence = { character: run[1]![0]!, length: run[1]!.length }
      code.fill(1, offset, offset + line.length)
    } else if (/^(?: {4}|\t)/.test(content)) {
      code.fill(1, offset, offset + line.length)
    }
    offset += line.length
  }
  for (let index = 0; index < source.length; index++) {
    if (code[index] || source[index] !== "`" || escaped(source, index)) continue
    let end = index + 1
    while (source[end] === "`") end++
    const marker = source.slice(index, end)
    let closing = source.indexOf(marker, end)
    while (
      closing !== -1 &&
      (source[closing - 1] === "`" || source[closing + marker.length] === "`" || code[closing])
    ) {
      closing = source.indexOf(marker, closing + marker.length)
    }
    if (closing !== -1) {
      code.fill(1, index, closing + marker.length)
      index = closing + marker.length - 1
    } else index = end - 1
  }
  const references: Array<MarkdownFileReference> = []
  const links = /!?\[[^\]\n]*\]\(\s*(?:<([^>\n]+)>|([^\s)]+))(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)/g
  for (const match of source.matchAll(links)) {
    if (
      escaped(source, match.index) ||
      code.slice(match.index, match.index + match[0].length).some(Boolean)
    )
      continue
    const target = match[1] ?? match[2]!
    const relativeStart = match[0].indexOf(target, match[0].indexOf("]("))
    references.push({
      start: match.index + relativeStart,
      end: match.index + relativeStart + target.length,
      target,
      embedded: match[0].startsWith("!")
    })
  }
  return references
}

export const localArtifactPath = (target: string, cwd: string | undefined): string | undefined => {
  if (target.startsWith("#") || target.startsWith("//")) return undefined
  try {
    if (target.startsWith("file://")) return fileURLToPath(target)
    if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(target)) return undefined
    const decoded = decodeURIComponent(target)
    if (decoded.startsWith("~/")) return resolve(homedir(), decoded.slice(2))
    if (isAbsolute(decoded)) return decoded
    return cwd === undefined ? undefined : resolve(cwd, decoded)
  } catch {
    return undefined
  }
}

const sourceExtensions = new Set([
  ".c",
  ".cc",
  ".cpp",
  ".h",
  ".hpp",
  ".rs",
  ".go",
  ".py",
  ".rb",
  ".sh",
  ".swift",
  ".js",
  ".jsx",
  ".ts",
  ".tsx",
  ".java",
  ".kt",
  ".css",
  ".scss",
  ".sql",
  ".toml",
  ".yaml",
  ".yml",
  ".md",
  ".json"
])

export const shouldCaptureFile = (reference: MarkdownFileReference): boolean =>
  reference.embedded ||
  (!/(?:#L\d+(?:-L?\d+)?|:\d+(?::\d+)?)$/.test(reference.target) &&
    extname(reference.target) !== "" &&
    !sourceExtensions.has(extname(reference.target).toLowerCase()))
