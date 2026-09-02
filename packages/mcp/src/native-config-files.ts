import { randomUUID } from "node:crypto"
import { mkdir, readFile, rename, writeFile } from "node:fs/promises"
import { dirname, join } from "node:path"
import * as jsonc from "jsonc-parser"
import { parse as parseToml } from "smol-toml"
import { parse as parseYaml } from "yaml"

/// Filesystem seam for reading (and, for writable formats, surgically
/// editing) harness-owned config files. Mirrors the AgentSessionFileSystem
/// pattern (agent-runtime/agent-sessions.ts) so scanners are unit-testable
/// without touching a real home directory.
export interface NativeConfigFileSystem {
  /// Returns the file's contents, or undefined when it does not exist.
  /// Non-ENOENT failures (permissions, I/O) throw.
  readonly readFile: (path: string) => Promise<string | undefined>
  /// Write via temp-file-plus-rename in the same directory, creating parent
  /// directories as needed — a crash mid-write never truncates the original.
  readonly writeFileAtomic: (path: string, content: string) => Promise<void>
}

export const defaultNativeConfigFileSystem: NativeConfigFileSystem = {
  readFile: async (path) => {
    try {
      return await readFile(path, "utf8")
    } catch (cause) {
      if ((cause as NodeJS.ErrnoException).code === "ENOENT") return undefined
      throw cause
    }
  },
  writeFileAtomic: async (path, content) => {
    await mkdir(dirname(path), { recursive: true })
    const temp = join(dirname(path), `.${randomUUID()}.tmp`)
    await writeFile(temp, content, "utf8")
    await rename(temp, path)
  }
}

/// A native config edit Codevisor refuses to perform because it cannot be
/// done without risking damage to the user's file (entry defined in a shape
/// the surgical editors don't handle, or a post-edit verification mismatch).
export class NativeConfigUnsupportedError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "NativeConfigUnsupportedError"
  }
}

export interface NativePathEnvironment {
  readonly home: string
  readonly env?: Readonly<Record<string, string | undefined>>
}

/// Resolve a catalog `~/`-relative config path against a home directory,
/// honoring the env overrides harnesses themselves respect: CODEX_HOME
/// relocates `~/.codex/...` and XDG_CONFIG_HOME relocates `~/.config/...`.
export const resolveNativeConfigPath = (
  specPath: string,
  environment: NativePathEnvironment
): string => {
  const env = environment.env ?? {}
  const codexHome = env["CODEX_HOME"]
  if (codexHome !== undefined && codexHome !== "" && specPath.startsWith("~/.codex/")) {
    return join(codexHome, specPath.slice("~/.codex/".length))
  }
  const xdgConfigHome = env["XDG_CONFIG_HOME"]
  if (xdgConfigHome !== undefined && xdgConfigHome !== "" && specPath.startsWith("~/.config/")) {
    return join(xdgConfigHome, specPath.slice("~/.config/".length))
  }
  if (specPath.startsWith("~/")) {
    return join(environment.home, specPath.slice(2))
  }
  return specPath
}

/// Parse a harness config file tolerantly. JSON accepts comments and trailing
/// commas (Claude/VS Code-family configs are JSONC in practice). Throws when
/// the content cannot be read as an object at all — callers surface that as a
/// per-harness scan error, never a 500.
export const parseNativeConfig = (
  content: string,
  format: "json" | "toml" | "yaml"
): Record<string, unknown> => {
  if (content.trim() === "") return {}
  let parsed: unknown
  switch (format) {
    case "json": {
      // Comments and trailing commas are tolerated silently; anything jsonc
      // still reports is real malformation, not formatting looseness.
      const errors: Array<jsonc.ParseError> = []
      parsed = jsonc.parse(content, errors, { allowTrailingComma: true })
      const firstError = errors[0]
      if (firstError !== undefined) {
        throw new Error(
          `invalid JSON at offset ${firstError.offset}: ${jsonc.printParseErrorCode(firstError.error)}`
        )
      }
      break
    }
    case "toml":
      parsed = parseToml(content)
      break
    case "yaml":
      parsed = parseYaml(content)
      break
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`config root is not an object (${format})`)
  }
  return parsed as Record<string, unknown>
}

/// Walk a dotted key path ("mcp_servers", "a.b.c") through nested records.
/// Ported from add-mcp formats/utils.ts.
export const getNestedValue = (obj: Record<string, unknown>, path: string): unknown => {
  let current: unknown = obj
  for (const key of path.split(".")) {
    if (current !== null && typeof current === "object" && key in current) {
      current = (current as Record<string, unknown>)[key]
    } else {
      return undefined
    }
  }
  return current
}

/// Detect the indentation style of a JSONC document so surgical edits match
/// the user's formatting. Ported from add-mcp formats/json.ts.
export const detectIndent = (
  text: string
): { readonly tabSize: number; readonly insertSpaces: boolean } => {
  let result: { tabSize: number; insertSpaces: boolean } | null = null
  jsonc.visit(text, {
    onObjectProperty: (_property, offset, _length, startLine, startCharacter) => {
      if (result === null && startLine > 0 && startCharacter > 0) {
        const lineStart = text.lastIndexOf("\n", offset - 1) + 1
        const whitespace = text.slice(lineStart, offset)
        result = { insertSpaces: !whitespace.includes("\t"), tabSize: startCharacter }
      }
    }
  })
  return result ?? { insertSpaces: true, tabSize: 2 }
}
