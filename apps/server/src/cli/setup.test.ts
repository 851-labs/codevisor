import { describe, expect, it } from "vitest"
import {
  addMachineDeeplink,
  detectPublicIp,
  detectTailscale,
  setupCommand,
  type SelectChoice,
  type SetupDeps
} from "./setup.js"
import { DEFAULT_PORT, type ExecResult } from "./support.js"

interface FakeOptions {
  readonly exec?: Record<string, ExecResult>
  readonly http?: Record<string, ReadonlyArray<{ status: number; body?: unknown } | undefined>>
  readonly env?: Record<string, string | undefined>
  readonly isInteractive?: boolean
  /// Values returned by successive select prompts (by index).
  readonly selections?: ReadonlyArray<string>
  /// Values returned by successive text prompts (by index).
  readonly textEntries?: ReadonlyArray<string>
}

interface FakeWorld {
  readonly deps: SetupDeps
  readonly logs: string[]
  readonly errors: string[]
  readonly selectMessages: string[]
  readonly selectChoices: Array<ReadonlyArray<SelectChoice<unknown>>>
}

const failure: ExecResult = { code: 1, stdout: "", stderr: "" }

const makeWorld = (options: FakeOptions = {}): FakeWorld => {
  const logs: string[] = []
  const errors: string[] = []
  const selectMessages: string[] = []
  const selectChoices: Array<ReadonlyArray<SelectChoice<unknown>>> = []
  const httpCounts = new Map<string, number>()
  let selectIndex = 0
  let textIndex = 0

  const deps: SetupDeps = {
    exec: (command, args) =>
      Promise.resolve(options.exec?.[[command, ...args].join(" ")] ?? failure),
    /* v8 ignore next 3 -- setup never runs interactive child processes. */
    execInteractive: () => Promise.resolve(0),
    spawnDetachedServer: () => Promise.resolve(4242),
    fetchJson: (url, init) => {
      const key = `${init?.method ?? "GET"} ${url}`
      const responses = options.http?.[key] ?? [undefined]
      const index = httpCounts.get(key) ?? 0
      httpCounts.set(key, index + 1)
      const response = responses[Math.min(index, responses.length - 1)]
      return Promise.resolve(
        response === undefined ? undefined : { status: response.status, body: response.body }
      )
    },
    readTextFile: () => undefined,
    writeTextFile: () => undefined,
    removeFile: () => undefined,
    processAlive: () => false,
    signal: () => true,
    sleep: () => Promise.resolve(),
    env: options.env ?? {},
    isRoot: false,
    installedVersion: () => undefined,
    dataDir: "/home/user/.codevisor/data",
    logsDir: "/home/user/.codevisor/logs",
    log: (line) => void logs.push(line),
    error: (line) => void errors.push(line),
    hostname: "build-box",
    isInteractive: options.isInteractive ?? true,
    prompts: {
      select: <A>(message: string, choices: ReadonlyArray<SelectChoice<A>>) => {
        selectMessages.push(message)
        selectChoices.push(choices)
        const value = options.selections?.[selectIndex] ?? choices[0]?.value
        selectIndex += 1
        return Promise.resolve(value as A)
      },
      text: () => {
        const value = options.textEntries?.[textIndex] ?? ""
        textIndex += 1
        return Promise.resolve(value)
      }
    }
  }
  return { deps, logs, errors, selectMessages, selectChoices }
}

const tailscaleStatus = (options: { dnsName?: string } = {}): ExecResult => ({
  code: 0,
  stdout: JSON.stringify({
    Self: {
      TailscaleIPs: ["100.101.102.103", "fd7a::1"],
      ...(options.dnsName === undefined ? {} : { DNSName: options.dnsName })
    }
  }),
  stderr: ""
})

const health = `GET http://127.0.0.1:${DEFAULT_PORT}/v1/health`
const pairing = `GET http://127.0.0.1:${DEFAULT_PORT}/v1/auth/connection-token`
const ok = { status: 200, body: { ok: true } }
const tokenResponse = { status: 200, body: { token: "hm_setup" } }

describe("codevisor setup", () => {
  it("detects tailscale from the CLI and the app bundle binary", async () => {
    const cli = makeWorld({
      exec: { "tailscale status --json": tailscaleStatus({ dnsName: "box.tail.net." }) }
    })
    expect(await detectTailscale(cli.deps)).toEqual({
      ip: "100.101.102.103",
      dnsName: "box.tail.net"
    })

    const app = makeWorld({
      exec: {
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json": tailscaleStatus()
      }
    })
    expect(await detectTailscale(app.deps)).toEqual({ ip: "100.101.102.103" })

    const missing = makeWorld()
    expect(await detectTailscale(missing.deps)).toBeUndefined()

    const garbage = makeWorld({
      exec: { "tailscale status --json": { code: 0, stdout: "not json", stderr: "" } }
    })
    expect(await detectTailscale(garbage.deps)).toBeUndefined()

    const loggedOut = makeWorld({
      exec: {
        "tailscale status --json": {
          code: 0,
          stdout: JSON.stringify({ Self: { TailscaleIPs: [] } }),
          stderr: ""
        }
      }
    })
    expect(await detectTailscale(loggedOut.deps)).toBeUndefined()

    const noIpList = makeWorld({
      exec: {
        "tailscale status --json": { code: 0, stdout: JSON.stringify({ Self: {} }), stderr: "" }
      }
    })
    expect(await detectTailscale(noIpList.deps)).toBeUndefined()
  })

  it("detects the public ip via the echo service", async () => {
    const world = makeWorld({
      http: {
        "GET https://api.ipify.org?format=json": [{ status: 200, body: { ip: "203.0.113.7" } }]
      }
    })
    expect(await detectPublicIp(world.deps)).toBe("203.0.113.7")

    const offline = makeWorld()
    expect(await detectPublicIp(offline.deps)).toBeUndefined()

    const empty = makeWorld({
      http: { "GET https://api.ipify.org?format=json": [{ status: 200, body: { ip: "" } }] }
    })
    expect(await detectPublicIp(empty.deps)).toBeUndefined()
  })

  it("builds url-encoded deeplinks", () => {
    expect(
      addMachineDeeplink({ host: "box.tail.net", port: 49361, token: "hm_x", name: "Büld Box" })
    ).toBe("codevisor://add-machine?host=box.tail.net&port=49361&token=hm_x&name=B%C3%BCld+Box")
  })

  it("skips under CODEVISOR_NO_SETUP and refuses non-interactive terminals", async () => {
    const skipped = makeWorld({ env: { CODEVISOR_NO_SETUP: "1" } })
    expect(await setupCommand(skipped.deps)).toBe(0)
    expect(skipped.logs[0]).toContain("Skipping setup")

    const nonTty = makeWorld({ isInteractive: false })
    expect(await setupCommand(nonTty.deps)).toBe(1)
    expect(nonTty.errors[0]).toContain("interactive terminal")
  })

  it("onboards over tailscale with the recommended choice first", async () => {
    const world = makeWorld({
      exec: { "tailscale status --json": tailscaleStatus({ dnsName: "box.tail.net." }) },
      http: { [health]: [ok], [pairing]: [tokenResponse] }
    })
    expect(await setupCommand(world.deps)).toBe(0)
    expect(world.selectChoices[0]?.[0]?.title).toBe("Tailscale (recommended)")
    const output = world.logs.join("\n")
    expect(output).toContain("Name               build-box")
    expect(output).toContain("Host               box.tail.net")
    expect(output).not.toContain(`Host               box.tail.net:${DEFAULT_PORT}`)
    expect(output).toContain("Connection token   hm_setup")
    expect(output).not.toContain("  Machine   ")
    expect(output).not.toContain("  Address   ")
    expect(output).not.toContain("  Port      ")
    expect(output).not.toContain("  Token     ")
    expect(output).toContain(
      "codevisor://add-machine?host=box.tail.net&port=49361&token=hm_setup&name=build-box"
    )
    expect(output).not.toContain("Firewall")
  })

  it("onboards over a detected public ip with a firewall note", async () => {
    const world = makeWorld({
      http: {
        [health]: [ok],
        [pairing]: [tokenResponse],
        "GET https://api.ipify.org?format=json": [{ status: 200, body: { ip: "203.0.113.7" } }]
      },
      selections: ["public"]
    })
    expect(await setupCommand(world.deps)).toBe(0)
    const output = world.logs.join("\n")
    expect(output).toContain("Tip: Tailscale is the recommended way")
    expect(output).toContain("Host               203.0.113.7")
    expect(output).toContain(`Firewall: allow inbound TCP ${DEFAULT_PORT}`)
    // Without tailscale, the recommended choice is absent.
    expect(world.selectChoices[0]?.some((choice) => choice.title.includes("Tailscale"))).toBe(false)
  })

  it("falls back to manual entry when the public ip cannot be detected", async () => {
    const world = makeWorld({
      http: { [health]: [ok], [pairing]: [tokenResponse] },
      selections: ["public"],
      textEntries: [" 198.51.100.4 "]
    })
    expect(await setupCommand(world.deps)).toBe(0)
    expect(world.logs.join("\n")).toContain("Host               198.51.100.4")

    const abandoned = makeWorld({
      http: { [health]: [ok] },
      selections: ["public"],
      textEntries: [""]
    })
    expect(await setupCommand(abandoned.deps)).toBe(1)
    expect(abandoned.errors[0]).toContain("No address entered")
  })

  it("accepts a custom address for BYO VPN setups", async () => {
    const world = makeWorld({
      http: { [health]: [ok], [pairing]: [tokenResponse] },
      selections: ["custom"],
      textEntries: ["10.8.0.5"]
    })
    expect(await setupCommand(world.deps)).toBe(0)
    expect(world.logs.join("\n")).toContain("Host               10.8.0.5")

    const customPort = 40000
    const nonDefaultPort = makeWorld({
      http: {
        [`GET http://127.0.0.1:${customPort}/v1/health`]: [ok],
        [`GET http://127.0.0.1:${customPort}/v1/auth/connection-token`]: [tokenResponse]
      },
      selections: ["custom"],
      textEntries: ["10.8.0.5"]
    })
    expect(await setupCommand(nonDefaultPort.deps, { port: customPort })).toBe(0)
    expect(nonDefaultPort.logs.join("\n")).toContain(`Host               10.8.0.5:${customPort}`)

    const empty = makeWorld({
      http: { [health]: [ok] },
      selections: ["custom"],
      textEntries: ["  "]
    })
    expect(await setupCommand(empty.deps)).toBe(1)
  })

  it("fails cleanly when the server cannot start or issue a token", async () => {
    // Health never succeeds and the spawned server never comes up.
    const noServer = makeWorld()
    expect(await setupCommand(noServer.deps)).toBe(1)

    const noToken = makeWorld({
      exec: { "tailscale status --json": tailscaleStatus() },
      http: { [health]: [ok] }
    })
    expect(await setupCommand(noToken.deps)).toBe(1)
    expect(noToken.errors[0]).toContain("connection token")
  })
})
