import { describe, expect, it } from "vitest"
import {
  checkBrewLatest,
  checkGithubLatest,
  checkNpmLatest,
  detectBrewPackage,
  detectInstallOrigin,
  isNewerVersion,
  type FetchLike
} from "./harness-update-sources.js"

const jsonResponse = (body: unknown, status = 200) => ({
  ok: status >= 200 && status < 300,
  status,
  json: async () => body,
  text: async () => JSON.stringify(body)
})

const fetchStub =
  (routes: Record<string, unknown>): FetchLike =>
  async (url) => {
    const body = routes[url]
    return body === undefined ? jsonResponse({ error: "not found" }, 404) : jsonResponse(body)
  }

describe("isNewerVersion", () => {
  it("compares dotted numeric cores and tolerates prefixes/suffixes", () => {
    expect(isNewerVersion("0.145.0", "0.144.5")).toBe(true)
    expect(isNewerVersion("v2.0.0", "1.9.9")).toBe(true)
    expect(isNewerVersion("1.2.3", "1.2.3")).toBe(false)
    expect(isNewerVersion("1.2.3-beta.1", "1.2.3")).toBe(false)
    expect(isNewerVersion("26.715.52143", "26.715.31925")).toBe(true)
    // Unequal segment counts pad with zeros on either side.
    expect(isNewerVersion("1.2.1", "1.2")).toBe(true)
    expect(isNewerVersion("1.2", "1.2.1")).toBe(false)
  })
})

describe("latest-version checkers", () => {
  it("reads npm dist-tags", async () => {
    const fetchImpl = fetchStub({
      "https://registry.npmjs.org/@openai/codex": { "dist-tags": { latest: "0.99.0" } }
    })
    await expect(checkNpmLatest("@openai/codex", "latest", fetchImpl)).resolves.toEqual({
      channel: "latest",
      latestVersion: "0.99.0"
    })
    // Unknown package or offline → silence, never an error.
    await expect(checkNpmLatest("@nope/nope", "latest", fetchImpl)).resolves.toEqual({})
  })

  it("reads brew formulas and falls back to casks", async () => {
    const fetchImpl = fetchStub({
      "https://formulae.brew.sh/api/formula/block-goose-cli.json": {
        versions: { stable: "1.24.0" }
      },
      "https://formulae.brew.sh/api/cask/codex.json": { version: "0.98.0" }
    })
    await expect(checkBrewLatest("block-goose-cli", fetchImpl)).resolves.toEqual({
      channel: "stable",
      latestVersion: "1.24.0"
    })
    await expect(checkBrewLatest("codex", fetchImpl)).resolves.toEqual({
      channel: "stable",
      latestVersion: "0.98.0"
    })
    await expect(checkBrewLatest("missing", fetchImpl)).resolves.toEqual({})
  })

  it("reads GitHub releases and strips tag prefixes", async () => {
    const fetchImpl = fetchStub({
      "https://api.github.com/repos/block/goose/releases/latest": { tag_name: "v1.24.0" }
    })
    await expect(checkGithubLatest("block/goose", fetchImpl)).resolves.toEqual({
      channel: "stable",
      latestVersion: "1.24.0"
    })
  })

  it("stays silent when the network itself fails", async () => {
    const failingFetch: FetchLike = async () => {
      throw new Error("offline")
    }
    await expect(checkNpmLatest("@openai/codex", "latest", failingFetch)).resolves.toEqual({})
    await expect(checkGithubLatest("block/goose", failingFetch)).resolves.toEqual({})
    await expect(checkBrewLatest("codex", failingFetch)).resolves.toEqual({})
  })

  it("stays silent on responses without usable versions", async () => {
    const fetchImpl = fetchStub({
      "https://registry.npmjs.org/tagless": { name: "tagless" },
      "https://api.github.com/repos/x/versionless/releases/latest": { tag_name: "stable" },
      "https://api.github.com/repos/x/tagless/releases/latest": {},
      "https://formulae.brew.sh/api/formula/hollow.json": { versions: {} },
      "https://formulae.brew.sh/api/cask/hollow.json": { version: "" }
    })
    // Registry document without the requested dist-tag.
    await expect(checkNpmLatest("tagless", "latest", fetchImpl)).resolves.toEqual({})
    // Release tag with no digits strips to nothing; absent tags too.
    await expect(checkGithubLatest("x/versionless", fetchImpl)).resolves.toEqual({})
    await expect(checkGithubLatest("x/tagless", fetchImpl)).resolves.toEqual({})
    // Formula without a stable version falls to the cask, which is empty too.
    await expect(checkBrewLatest("hollow", fetchImpl)).resolves.toEqual({})
  })
})

describe("detectInstallOrigin", () => {
  const home = "/Users/dev"

  it("classifies npm globals behind brew-node symlinks as npm, not brew", () => {
    // /opt/homebrew/bin/<cli> is a symlink into homebrew's node_modules when
    // node came from brew — the real path decides.
    expect(
      detectInstallOrigin("/opt/homebrew/bin/gemini", {
        home,
        realpath: () => "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js"
      })
    ).toBe("npm")
  })

  it("classifies brew-owned binaries via Cellar/Caskroom", () => {
    expect(
      detectInstallOrigin("/opt/homebrew/bin/goose", {
        home,
        realpath: () => "/opt/homebrew/Cellar/block-goose-cli/1.0.0/bin/goose"
      })
    ).toBe("brew")
    expect(
      detectInstallOrigin("/opt/homebrew/bin/codex", {
        home,
        realpath: () => "/opt/homebrew/Caskroom/codex/0.98.0/codex"
      })
    ).toBe("brew")
  })

  it("classifies app-bundled binaries", () => {
    expect(
      detectInstallOrigin("/Applications/ChatGPT.app/Contents/Resources/codex", {
        home,
        realpath: (path) => path
      })
    ).toBe("appBundle")
  })

  it("classifies home-dot-directory installs as curl and plain home paths as standalone", () => {
    expect(
      detectInstallOrigin("/Users/dev/.local/bin/claude", { home, realpath: (path) => path })
    ).toBe("curl")
    expect(
      detectInstallOrigin("/Users/dev/.codex/packages/standalone/releases/1/codex", {
        home,
        realpath: (path) => path
      })
    ).toBe("curl")
    expect(detectInstallOrigin("/Users/dev/bin/tool", { home, realpath: (path) => path })).toBe(
      "standalone"
    )
  })

  it("classifies system paths and unknowns", () => {
    expect(detectInstallOrigin("/usr/local/bin/thing", { home, realpath: (path) => path })).toBe(
      "standalone"
    )
    expect(detectInstallOrigin("/srv/agents/thing", { home, realpath: (path) => path })).toBe(
      "unknown"
    )
  })

  it("uses the real filesystem resolver and process HOME by default", () => {
    const savedHome = process.env.HOME
    try {
      // A real path (the temp root) resolves through the default realpathSync
      // and classifies against the process's own HOME…
      expect(detectInstallOrigin("/tmp")).toBeDefined()
      // …and an unset HOME skips home-directory classification entirely.
      delete process.env.HOME
      expect(detectInstallOrigin("/srv/agents/thing", { realpath: (path) => path })).toBe("unknown")
    } finally {
      if (savedHome !== undefined) process.env.HOME = savedHome
    }
  })

  it("falls back to the literal path when realpath fails", () => {
    expect(
      detectInstallOrigin("/opt/homebrew/Cellar/x/1/bin/x", {
        home,
        realpath: () => {
          throw new Error("ENOENT")
        }
      })
    ).toBe("brew")
  })
})

describe("detectBrewPackage", () => {
  it("preserves exact formula and cask channels from resolved symlinks", () => {
    expect(
      detectBrewPackage("/opt/homebrew/bin/claude", {
        realpath: () => "/opt/homebrew/Caskroom/claude-code@latest/2.1.216/claude"
      })
    ).toEqual({ cask: true, formula: "claude-code@latest" })
    expect(
      detectBrewPackage("/opt/homebrew/bin/claude", {
        realpath: () => "/opt/homebrew/Caskroom/claude-code/2.1.206/claude"
      })
    ).toEqual({ cask: true, formula: "claude-code" })
    expect(
      detectBrewPackage("/usr/local/bin/tool", {
        realpath: () => "/usr/local/Cellar/tool@2/2.4.0/bin/tool"
      })
    ).toEqual({ cask: false, formula: "tool@2" })
  })

  it("returns undefined when Homebrew does not own the binary", () => {
    expect(
      detectBrewPackage("/Users/dev/.local/bin/claude", { realpath: (path) => path })
    ).toBeUndefined()
    expect(
      detectBrewPackage("/opt/homebrew/bin/claude", {
        realpath: () => "/opt/homebrew/Caskroom/claude;echo-owned/1/claude"
      })
    ).toBeUndefined()
  })
})
