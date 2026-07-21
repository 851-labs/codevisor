import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterAll, describe, expect, it } from "vitest"
import {
  appendTomlTable,
  defaultNativeConfigFileSystem,
  detectIndent,
  extractServerIdentity,
  getNestedValue,
  NativeConfigUnsupportedError,
  normalizeNativeServer,
  normalizeUrlIdentity,
  parseNativeConfig,
  removeJsonConfigKey,
  removeTomlTable,
  resolveNativeConfigPath,
  setJsonConfigValue
} from "./native-config-files.js"

const cleanups: Array<() => Promise<void>> = []

afterAll(async () => {
  for (const cleanup of cleanups) await cleanup()
})

const makeTempDir = async (): Promise<string> => {
  const dir = await mkdtemp(join(tmpdir(), "native-config-"))
  cleanups.push(() => rm(dir, { force: true, recursive: true }))
  return dir
}

describe("defaultNativeConfigFileSystem", () => {
  it("reads existing files", async () => {
    const dir = await makeTempDir()
    const path = join(dir, "config.json")
    await writeFile(path, "{}")
    await expect(defaultNativeConfigFileSystem.readFile(path)).resolves.toBe("{}")
  })

  it("returns undefined for missing files", async () => {
    const dir = await makeTempDir()
    await expect(
      defaultNativeConfigFileSystem.readFile(join(dir, "absent.json"))
    ).resolves.toBeUndefined()
  })

  it("propagates non-ENOENT failures", async () => {
    const dir = await makeTempDir()
    // Reading a directory as a file fails with EISDIR, not ENOENT.
    await expect(defaultNativeConfigFileSystem.readFile(dir)).rejects.toThrow()
  })

  it("writes atomically, creating parent directories and leaving no temp files", async () => {
    const dir = await makeTempDir()
    const path = join(dir, "nested/deep/config.json")
    await defaultNativeConfigFileSystem.writeFileAtomic(path, "{}")
    await expect(defaultNativeConfigFileSystem.readFile(path)).resolves.toBe("{}")
    await defaultNativeConfigFileSystem.writeFileAtomic(path, `{"a":1}`)
    await expect(defaultNativeConfigFileSystem.readFile(path)).resolves.toBe(`{"a":1}`)
    const { readdir } = await import("node:fs/promises")
    expect((await readdir(join(dir, "nested/deep"))).filter((f) => f.endsWith(".tmp"))).toEqual([])
  })
})

describe("resolveNativeConfigPath", () => {
  it("expands ~/ against the home directory", () => {
    expect(resolveNativeConfigPath("~/.claude.json", { home: "/Users/u" })).toBe(
      "/Users/u/.claude.json"
    )
  })

  it("prefers CODEX_HOME for ~/.codex paths", () => {
    expect(
      resolveNativeConfigPath("~/.codex/config.toml", {
        env: { CODEX_HOME: "/elsewhere/codex" },
        home: "/Users/u"
      })
    ).toBe("/elsewhere/codex/config.toml")
  })

  it("ignores empty CODEX_HOME", () => {
    expect(
      resolveNativeConfigPath("~/.codex/config.toml", {
        env: { CODEX_HOME: "" },
        home: "/Users/u"
      })
    ).toBe("/Users/u/.codex/config.toml")
  })

  it("prefers XDG_CONFIG_HOME for ~/.config paths", () => {
    expect(
      resolveNativeConfigPath("~/.config/opencode/opencode.json", {
        env: { XDG_CONFIG_HOME: "/xdg" },
        home: "/Users/u"
      })
    ).toBe("/xdg/opencode/opencode.json")
  })

  it("ignores empty XDG_CONFIG_HOME", () => {
    expect(
      resolveNativeConfigPath("~/.config/opencode/opencode.json", {
        env: { XDG_CONFIG_HOME: "" },
        home: "/Users/u"
      })
    ).toBe("/Users/u/.config/opencode/opencode.json")
  })

  it("leaves absolute paths untouched", () => {
    expect(resolveNativeConfigPath("/etc/config.json", { home: "/Users/u" })).toBe(
      "/etc/config.json"
    )
  })
})

describe("parseNativeConfig", () => {
  it("treats blank content as an empty object", () => {
    expect(parseNativeConfig("  \n", "json")).toEqual({})
  })

  it("parses JSON with comments and trailing commas", () => {
    const content = `{
  // servers
  "mcpServers": { "a": { "command": "run" }, },
}`
    expect(parseNativeConfig(content, "json")).toEqual({
      mcpServers: { a: { command: "run" } }
    })
  })

  it("parses TOML tables", () => {
    const content = `[mcp_servers.docs]
command = "npx"
args = ["-y", "docs-mcp"]
`
    expect(parseNativeConfig(content, "toml")).toEqual({
      mcp_servers: { docs: { args: ["-y", "docs-mcp"], command: "npx" } }
    })
  })

  it("parses YAML documents", () => {
    const content = `extensions:
  docs:
    cmd: uvx
`
    expect(parseNativeConfig(content, "yaml")).toEqual({
      extensions: { docs: { cmd: "uvx" } }
    })
  })

  it("rejects non-object roots", () => {
    expect(() => parseNativeConfig("[1, 2]", "json")).toThrow("config root is not an object")
    expect(() => parseNativeConfig("null", "yaml")).toThrow("config root is not an object")
    expect(() => parseNativeConfig("garbage {", "json")).toThrow("invalid JSON at offset")
  })

  it("propagates TOML syntax failures", () => {
    expect(() => parseNativeConfig("= broken", "toml")).toThrow()
  })
})

describe("getNestedValue", () => {
  const obj = { mcp: { servers: { a: 1 } } }

  it("walks dotted paths", () => {
    expect(getNestedValue(obj, "mcp.servers")).toEqual({ a: 1 })
  })

  it("returns undefined for missing segments", () => {
    expect(getNestedValue(obj, "mcp.missing.deep")).toBeUndefined()
  })

  it("returns undefined when traversing through non-objects", () => {
    expect(getNestedValue({ mcp: null } as never, "mcp.servers")).toBeUndefined()
  })
})

describe("detectIndent", () => {
  it("detects space indentation width", () => {
    expect(detectIndent(`{\n    "a": 1\n}`)).toEqual({ insertSpaces: true, tabSize: 4 })
  })

  it("detects tab indentation", () => {
    expect(detectIndent(`{\n\t"a": 1\n}`)).toEqual({ insertSpaces: false, tabSize: 1 })
  })

  it("defaults to two spaces for flat documents", () => {
    expect(detectIndent(`{"a": 1}`)).toEqual({ insertSpaces: true, tabSize: 2 })
  })
})

describe("normalizeNativeServer", () => {
  it("skips non-object entries", () => {
    expect(normalizeNativeServer("claude-code", null)).toBeUndefined()
    expect(normalizeNativeServer("claude-code", "text")).toBeUndefined()
    expect(normalizeNativeServer("claude-code", [1])).toBeUndefined()
  })

  it("normalizes standard remote entries", () => {
    const normalized = normalizeNativeServer("claude-code", {
      headers: { Authorization: "Bearer x", broken: 3 },
      type: "http",
      url: "https://mcp.example.com/mcp"
    })
    expect(normalized).toMatchObject({
      headers: { Authorization: "Bearer x" },
      transport: "http",
      url: "https://mcp.example.com/mcp"
    })
    expect(normalized?.enabled).toBeUndefined()
  })

  it("normalizes standard stdio entries", () => {
    expect(
      normalizeNativeServer("gemini", {
        args: ["-y", "docs-mcp", 7],
        command: "npx",
        env: { TOKEN: "secret" }
      })
    ).toMatchObject({
      args: ["-y", "docs-mcp"],
      command: "npx",
      env: { TOKEN: "secret" },
      transport: "stdio"
    })
  })

  it("skips standard entries with neither url nor command", () => {
    expect(normalizeNativeServer("claude-code", { type: "http" })).toBeUndefined()
  })

  it("normalizes opencode remote and local shapes", () => {
    expect(
      normalizeNativeServer("opencode", {
        enabled: false,
        headers: { "X-Key": "v" },
        type: "remote",
        url: "https://mcp.example.com"
      })
    ).toMatchObject({ enabled: false, transport: "http", url: "https://mcp.example.com" })
    expect(
      normalizeNativeServer("opencode", {
        command: ["bun", "server.ts"],
        environment: { KEY: "v" },
        type: "local"
      })
    ).toMatchObject({
      args: ["server.ts"],
      command: "bun",
      enabled: true,
      env: { KEY: "v" },
      transport: "stdio"
    })
  })

  it("skips opencode entries with an empty command array", () => {
    expect(normalizeNativeServer("opencode", { command: [], type: "local" })).toBeUndefined()
  })

  it("skips opencode entries with no command at all", () => {
    expect(normalizeNativeServer("opencode", { type: "local" })).toBeUndefined()
  })

  it("defaults absent args to an empty list", () => {
    expect(normalizeNativeServer("codex", { command: "docs-mcp" })).toMatchObject({
      args: [],
      command: "docs-mcp"
    })
  })

  it("normalizes codex remote and stdio shapes", () => {
    expect(
      normalizeNativeServer("codex", {
        http_headers: { Authorization: "Bearer t" },
        url: "https://mcp.example.com"
      })
    ).toMatchObject({
      headers: { Authorization: "Bearer t" },
      transport: "http",
      url: "https://mcp.example.com"
    })
    expect(
      normalizeNativeServer("codex", { args: ["serve"], command: "docs-mcp", env: { A: "1" } })
    ).toMatchObject({ args: ["serve"], command: "docs-mcp", env: { A: "1" }, transport: "stdio" })
    expect(normalizeNativeServer("codex", {})).toBeUndefined()
  })

  it("normalizes goose extension shapes", () => {
    expect(
      normalizeNativeServer("goose", {
        enabled: true,
        type: "streamable_http",
        uri: "https://mcp.example.com"
      })
    ).toMatchObject({ enabled: true, transport: "http", url: "https://mcp.example.com" })
    expect(
      normalizeNativeServer("goose", {
        args: ["mcp", "docs"],
        cmd: "uvx",
        enabled: false,
        envs: { KEY: "v" }
      })
    ).toMatchObject({
      args: ["mcp", "docs"],
      command: "uvx",
      enabled: false,
      env: { KEY: "v" },
      transport: "stdio"
    })
    expect(normalizeNativeServer("goose", { name: "broken" })).toBeUndefined()
  })

  it("normalizes cline shapes with the disabled flag", () => {
    expect(
      normalizeNativeServer("cline", {
        disabled: true,
        type: "streamableHttp",
        url: "https://mcp.example.com"
      })
    ).toMatchObject({ enabled: false, transport: "http" })
    expect(
      normalizeNativeServer("cline", { args: [], command: "docs-mcp", env: { A: "1" } })
    ).toMatchObject({ command: "docs-mcp", enabled: true, transport: "stdio" })
    expect(normalizeNativeServer("cline", { disabled: false })).toBeUndefined()
  })
})

describe("extractServerIdentity", () => {
  it("prefers url-like keys and normalizes them", () => {
    expect(extractServerIdentity({ url: "https://MCP.Example.com/path/" })).toBe(
      "https://mcp.example.com/path"
    )
    expect(extractServerIdentity({ uri: "https://a.example.com" })).toBe("https://a.example.com")
    expect(extractServerIdentity({ serverUrl: "https://b.example.com" })).toBe(
      "https://b.example.com"
    )
  })

  it("identifies npx/bunx invocations by package name", () => {
    expect(extractServerIdentity({ args: ["-y", "docs-mcp"], command: "npx" })).toBe("docs-mcp")
    expect(extractServerIdentity({ args: ["docs-mcp"], command: "bunx" })).toBe("docs-mcp")
    expect(extractServerIdentity({ command: ["bunx", "-y", "docs-mcp"] })).toBe("docs-mcp")
  })

  it("falls back to the flag-only npx command line", () => {
    expect(extractServerIdentity({ args: ["-y", "--quiet"], command: "npx" })).toBe(
      "npx -y --quiet"
    )
  })

  it("joins command arrays that are not package launchers", () => {
    expect(extractServerIdentity({ command: ["node", "server.js"] })).toBe("node server.js")
    expect(extractServerIdentity({ command: ["npx", "-y", "-x"] })).toBe("npx -y -x")
    expect(extractServerIdentity({ command: [] })).toBe("")
  })

  it("reconstructs plain command lines", () => {
    expect(extractServerIdentity({ args: ["--port", "1"], command: "docs-mcp" })).toBe(
      "docs-mcp --port 1"
    )
    expect(extractServerIdentity({ cmd: "uvx" })).toBe("uvx")
    expect(extractServerIdentity({})).toBe("")
  })
})

describe("normalizeUrlIdentity", () => {
  it("lowercases hosts and strips trailing slashes", () => {
    expect(normalizeUrlIdentity("https://MCP.Example.com/api/")).toBe("https://mcp.example.com/api")
  })

  it("preserves query strings", () => {
    expect(normalizeUrlIdentity("https://a.example.com/x?y=1")).toBe("https://a.example.com/x?y=1")
  })

  it("passes through non-http identities", () => {
    expect(normalizeUrlIdentity("docs-mcp")).toBe("docs-mcp")
  })

  it("passes through unparseable urls", () => {
    expect(normalizeUrlIdentity("https://")).toBe("https://")
  })
})

describe("surgical config editors", () => {
  describe("removeJsonConfigKey / setJsonConfigValue", () => {
    it("preserves tab indentation and comments", () => {
      const content = `{\n\t// keep\n\t"mcpServers": {\n\t\t"docs": { "command": "x" },\n\t\t"linear": { "url": "https://l" }\n\t}\n}`
      const after = removeJsonConfigKey(content, "mcpServers", "docs")
      expect(after).toContain("// keep")
      expect(after).toContain('\t"mcpServers"')
      expect(after).not.toContain("docs")
      expect(parseNativeConfig(after, "json")).toEqual({
        mcpServers: { linear: { url: "https://l" } }
      })
    })

    it("sets nested values and builds structure from empty content", () => {
      const withFlag = setJsonConfigValue(
        `{\n  "mcp": {\n    "local": { "type": "local" }\n  }\n}`,
        ["mcp", "local", "enabled"],
        false
      )
      expect(parseNativeConfig(withFlag, "json")).toEqual({
        mcp: { local: { enabled: false, type: "local" } }
      })
      const fromEmpty = setJsonConfigValue("", ["mcpServers", "docs"], { command: "x" })
      expect(parseNativeConfig(fromEmpty, "json")).toEqual({
        mcpServers: { docs: { command: "x" } }
      })
    })
  })

  describe("removeTomlTable", () => {
    it("removes quoted-name tables", () => {
      const content = `[mcp_servers."my docs"]\ncommand = "x"\n\n[mcp_servers.linear]\nurl = "https://l"\n`
      const after = removeTomlTable(content, "mcp_servers", "my docs")
      expect(after).toContain("[mcp_servers.linear]")
      expect(after).not.toContain("my docs")
    })

    it("removes the only entry, dropping the implicit parent", () => {
      const content = `model = "gpt"\n\n[mcp_servers.docs]\ncommand = "x"\n`
      const after = removeTomlTable(content, "mcp_servers", "docs")
      expect(parseNativeConfig(after, "toml")).toEqual({ model: "gpt" })
    })

    it("throws for missing entries", () => {
      expect(() =>
        removeTomlTable(`[mcp_servers.docs]\ncommand = "x"\n`, "mcp_servers", "ghost")
      ).toThrow(NativeConfigUnsupportedError)
    })

    it("refuses when the excision would corrupt the document", () => {
      // A multi-line nested array: its `[1, 2],` lines look like table
      // headers to the section scanner, so the excision is incomplete and
      // the reparse check must refuse.
      const content = `[mcp_servers.docs]\nmatrix = [\n  [1, 2],\n  [3, 4],\n]\n`
      expect(() => removeTomlTable(content, "mcp_servers", "docs")).toThrow(
        "would corrupt the file"
      )
    })
  })

  describe("appendTomlTable", () => {
    it("appends a table to existing content and to empty content", () => {
      const appended = appendTomlTable(`model = "gpt"\n`, "mcp_servers", "docs", {
        args: ["-y", "docs-mcp"],
        command: "npx"
      })
      expect(parseNativeConfig(appended, "toml")).toEqual({
        mcp_servers: { docs: { args: ["-y", "docs-mcp"], command: "npx" } },
        model: "gpt"
      })
      const fromEmpty = appendTomlTable("", "mcp_servers", "docs", { command: "npx" })
      expect(parseNativeConfig(fromEmpty, "toml")).toEqual({
        mcp_servers: { docs: { command: "npx" } }
      })
    })

    it("round-trips nested fragments through remove and append", () => {
      const original = `[mcp_servers.docs]\ncommand = "npx"\n\n[mcp_servers.docs.env]\nTOKEN = "secret"\n`
      const fragment = parseNativeConfig(original, "toml")["mcp_servers"] as Record<
        string,
        Record<string, unknown>
      >
      const removed = removeTomlTable(original, "mcp_servers", "docs")
      const restored = appendTomlTable(
        removed,
        "mcp_servers",
        "docs",
        fragment["docs"] as Record<string, unknown>
      )
      expect(parseNativeConfig(restored, "toml")).toEqual(parseNativeConfig(original, "toml"))
    })
  })
})
