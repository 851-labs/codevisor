import { describe, expect, it } from "vitest"

import { argumentPlaceholder, catalogEntryOf } from "./index.js"
import { registryServersOf } from "./registry-server.js"

const packaged = (registryType: string, extra: Record<string, unknown> = {}) => ({
  name: "io.github.acme/tool",
  version: "1.2.0",
  packages: [
    {
      registryType,
      identifier: "acme-tool",
      version: "1.2.0",
      transport: { type: "stdio" },
      ...extra
    }
  ]
})

describe("registry server.json to catalog entry", () => {
  it("installs a remote through its streamable HTTP URL with header fields", () => {
    const entry = catalogEntryOf(
      {
        name: "com.example/remote",
        icons: [{ src: "https://example.com/icon.png" }],
        websiteUrl: "https://example.com",
        remotes: [
          { type: "sse", url: "https://example.com/sse" },
          {
            type: "streamable-http",
            url: "https://example.com/mcp",
            headers: [
              { name: "X-Api-Key", isSecret: true, isRequired: true, description: "Key" },
              {}
            ]
          }
        ]
      },
      "registry"
    )
    expect(entry).toMatchObject({
      id: "com.example/remote",
      name: "remote",
      publisher: "com.example",
      version: "latest",
      transport: "http",
      url: "https://example.com/mcp",
      iconUrl: "https://example.com/icon.png",
      docsUrl: "https://example.com",
      install: {
        kind: "remote",
        url: "https://example.com/mcp",
        fields: [{ key: "header:X-Api-Key", type: "secret", required: true, help: "Key" }]
      }
    })
  })

  it("runs npm, pypi and oci packages with env vars as fields", () => {
    const env = [
      { name: "TOKEN", isSecret: true, isRequired: true },
      { name: "MODE", choices: ["a", "b"], default: "a" },
      { name: "VERBOSE", format: "boolean" },
      { name: "LIMIT", format: "number" }
    ]
    const npm = catalogEntryOf(packaged("npm", { environmentVariables: env }), "registry")!
    expect(npm.install).toEqual({
      kind: "package",
      registryType: "npm",
      command: "npx",
      args: ["-y", "acme-tool@1.2.0"],
      fields: [
        { key: "env:TOKEN", label: "TOKEN", type: "secret", required: true },
        {
          key: "env:MODE",
          label: "MODE",
          type: "choice",
          required: false,
          default: "a",
          choices: [
            { value: "a", label: "a" },
            { value: "b", label: "b" }
          ]
        },
        { key: "env:VERBOSE", label: "VERBOSE", type: "boolean", required: false },
        { key: "env:LIMIT", label: "LIMIT", type: "number", required: false }
      ]
    })
    expect(
      catalogEntryOf(packaged("pypi", { runtimeHint: "uvx" }), "registry")?.install
    ).toMatchObject({ command: "uvx", args: ["acme-tool==1.2.0"] })
    expect(
      catalogEntryOf(
        packaged("oci", { version: "latest", environmentVariables: [{ name: "TOKEN" }, {}] }),
        "registry"
      )?.install
    ).toMatchObject({
      command: "docker",
      args: ["run", "-i", "--rm", "-e", "TOKEN", "acme-tool"]
    })
  })

  it("asks for required package arguments and fills fixed ones", () => {
    const entry = catalogEntryOf(
      packaged("npm", {
        packageArguments: [
          { type: "positional", value: "serve" },
          { type: "named", name: "root", isRequired: true, description: "Root folder" },
          { type: "named", name: "--port", value: "8080" },
          { type: "positional", valueHint: "dir", isRequired: true },
          { type: "named", name: "optional" }
        ]
      }),
      "registry"
    )!
    expect(entry.install).toMatchObject({
      args: [
        "-y",
        "acme-tool@1.2.0",
        "serve",
        "--root",
        argumentPlaceholder(1),
        "--port",
        "8080",
        argumentPlaceholder(3)
      ],
      fields: [
        { key: "arg:1", label: "root", required: true, help: "Root folder" },
        { key: "arg:3", label: "dir", required: true }
      ]
    })
  })

  it("skips servers it can't run", () => {
    expect(catalogEntryOf(packaged("nuget"), "registry")).toBeUndefined()
    expect(
      catalogEntryOf(packaged("npm", { transport: { type: "streamable-http" } }), "registry")
    ).toBeUndefined()
    expect(catalogEntryOf({ name: "bare" }, "registry")).toBeUndefined()
  })

  it("reads registry list bodies leniently", () => {
    expect(
      registryServersOf({
        servers: [{ server: { name: "a/b" } }, { name: "c/d" }, { server: {} }, 3]
      }).map((server) => server.name)
    ).toEqual(["a/b", "c/d"])
    expect(registryServersOf(undefined)).toEqual([])
    expect(registryServersOf({ servers: "nope" })).toEqual([])
  })
})

describe("registry entry defaults", () => {
  it("falls back to default runners, labels and publishers", () => {
    expect(catalogEntryOf(packaged("pypi"), "registry")?.install).toMatchObject({ command: "uvx" })
    expect(
      catalogEntryOf({ ...packaged("npm", { runtimeHint: "bunx" }), name: "plain" }, "registry")
    ).toMatchObject({
      publisher: "plain",
      install: { command: "bunx" }
    })
    expect(catalogEntryOf(packaged("oci"), "registry")?.install).toMatchObject({
      args: ["run", "-i", "--rm", "acme-tool:1.2.0"]
    })
    expect(
      catalogEntryOf(
        packaged("npm", { packageArguments: [{ type: "positional", isRequired: true }] }),
        "registry"
      )?.install
    ).toMatchObject({ fields: [{ key: "arg:0", label: "0" }] })
  })
})

describe("publisher-provided registry metadata", () => {
  it("reads Codevisor metadata a third party published, but never as a bundled plugin", () => {
    const entry = catalogEntryOf(
      {
        ...packaged("npm"),
        _meta: {
          "io.modelcontextprotocol.registry/publisher-provided": {
            "dev.codevisor/plugin": {
              bundled: "grafana",
              capabilities: {
                tools: [{ name: "lookup" }],
                events: [],
                skills: [],
                panes: [],
                ingress: []
              }
            }
          }
        }
      },
      "registry"
    )
    expect(entry?.install.kind).toBe("package")
    expect(entry?.capabilities.tools).toEqual([{ name: "lookup" }])
    expect(
      catalogEntryOf(
        {
          ...packaged("npm"),
          _meta: { "io.modelcontextprotocol.registry/publisher-provided": { other: 1 } }
        },
        "registry"
      )?.capabilities.tools
    ).toEqual([])
    expect(
      catalogEntryOf(
        { ...packaged("npm"), _meta: { "io.modelcontextprotocol.registry/publisher-provided": 3 } },
        "registry"
      )?.install.kind
    ).toBe("package")
  })
})

const rated = (ageRating: unknown) =>
  catalogEntryOf(
    { ...packaged("npm"), _meta: { "dev.codevisor/plugin": { ageRating } } },
    "popular"
  )

describe("catalog age ratings", () => {
  it("keeps a known age band and drops anything else", () => {
    expect(rated(13)?.ageRating).toBe(13)
    expect(rated(7)).not.toHaveProperty("ageRating")
  })
})
