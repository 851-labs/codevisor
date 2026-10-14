import { randomUUID } from "node:crypto"
import { readFileSync, renameSync } from "node:fs"
import { mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { dirname, join } from "node:path"

import * as jsonc from "jsonc-parser"
import { parse as parseToml } from "smol-toml"
import { parse as parseYaml } from "yaml"

import { NativeMcpError } from "./native-mcp-types.js"

export interface NativeConfigFileSystem {
  readonly readFile: (path: string) => Promise<string | undefined>
  readonly writeFileAtomic: (
    path: string,
    content: string,
    expected?: { readonly content: string | undefined }
  ) => Promise<void>
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
  writeFileAtomic: async (path, content, expected) => {
    await mkdir(dirname(path), { recursive: true })
    const temp = join(dirname(path), `.${randomUUID()}.tmp`)
    try {
      await writeFile(temp, content, "utf8")
      if (expected !== undefined) {
        let current: string | undefined
        try {
          current = readFileSync(path, "utf8")
        } catch (cause) {
          if ((cause as NodeJS.ErrnoException).code !== "ENOENT") throw cause
        }
        if (current !== expected.content)
          throw new NativeMcpError(`${path} changed during the edit — try again`, "conflict")
      }
      renameSync(temp, path)
    } finally {
      await rm(temp, { force: true })
    }
  }
}

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

export const parseNativeConfig = (
  content: string,
  format: "json" | "toml" | "yaml"
): Record<string, unknown> => {
  if (content.trim() === "") return {}
  let parsed: unknown
  switch (format) {
    case "json": {
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
