import { type ChildProcess, execFileSync, spawn } from "node:child_process"
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises"
import { createServer, type RequestListener } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it, vi } from "vitest"

import { waitForExit } from "./child-processes.ts"
import { colorFromHash } from "./color.ts"
import { makeCommandRunner } from "./commands.ts"
import { terminateExactDevelopmentApp } from "./dev-app.ts"
import {
  applyCloudDevMigrations,
  cloudWranglerEnvironment,
  prepareCloudSession,
  resolveCloudDevInstance
} from "./dev-cloud.ts"
import { createDevelopmentAppIcon, createDevelopmentBrowserExtensionIcons } from "./dev-icons.ts"
import { developmentLayout } from "./dev-layout.ts"
import { resolveDevelopmentSigningArguments } from "./dev-signing.ts"

const cleanups: Array<() => Promise<unknown>> = []
afterEach(async () => {
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()))
})

const scratch = async () => {
  const directory = await mkdtemp(join(tmpdir(), "codevisor-host-test-"))
  cleanups.push(() => rm(directory, { recursive: true, force: true }))
  return directory
}

const listen = async (handler: RequestListener, host = "127.0.0.1"): Promise<number> => {
  const server = createServer(handler)
  await new Promise<void>((resolve) => server.listen(0, host, resolve))
  cleanups.push(() => new Promise((resolve) => server.close(resolve)))
  const address = server.address()
  if (address === null || typeof address === "string") throw new Error("expected a TCP address")
  return address.port
}

const running = (child: ChildProcess) => {
  cleanups.push(async () => child.kill("SIGKILL"))
  return child
}

describe("makeCommandRunner", () => {
  it("captures output and reports failures with their exit", async () => {
    const runner = makeCommandRunner(process.cwd())
    expect(await runner.capture(process.execPath, ["-e", "process.stdout.write('hi')"])).toBe("hi")
    await expect(runner.capture(process.execPath, ["-e", "process.exit(4)"])).rejects.toThrow(
      /failed \(code 4\)/
    )
    await runner.run(process.execPath, ["-e", ""])
    await expect(runner.run(process.execPath, ["-e", "process.exit(5)"])).rejects.toThrow(
      /failed \(code 5\)/
    )
  })
})

describe("development icons", () => {
  it("tints the dev app icon with the instance color", async () => {
    const repoRoot = await scratch()
    const template = join(repoRoot, "apps/macos/Codevisor/Resources/AppIconDev.icon")
    await mkdir(join(template, "Assets"), { recursive: true })
    await writeFile(join(template, "icon.json"), JSON.stringify({ fill: "old" }))
    await writeFile(join(template, "Assets/icon-v2.svg"), "<svg/>")

    const generated = await createDevelopmentAppIcon(repoRoot, colorFromHash("00000000"), "ios")

    expect(generated).toBe(join(repoRoot, "apps/ios/Codevisor/Resources/AppIconDevGenerated.icon"))
    expect(JSON.parse(await readFile(join(generated, "icon.json"), "utf8")).fill).toEqual({
      "automatic-gradient": colorFromHash("00000000").composer
    })
    expect(await readFile(join(generated, "Assets/icon-v2.svg"), "utf8")).toBe("<svg/>")
  })

  it("converts the built app's icon into the browser extension iconset", async () => {
    const calls: Array<Array<string>> = []
    const layout = developmentLayout("/repo", {})
    const iconset = await createDevelopmentBrowserExtensionIcons({
      appName: "Codevisor (x)",
      derivedDataPath: "/dd",
      layout,
      run: async (command, args) => {
        calls.push([command, ...args])
      }
    })

    expect(iconset).toBe(join(layout.build.generated, "BrowserExtensionDev.iconset"))
    expect(calls).toEqual([
      [
        "iconutil",
        "--convert",
        "iconset",
        "--output",
        iconset,
        "/dd/Build/Products/Debug/Codevisor (x).app/Contents/Resources/AppIconDevGenerated.icns"
      ]
    ])
  })
})

const identities =
  '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Test Person (ABCDE12345)"\n     1 valid identities found'
const certificate = (subject: string) =>
  execFileSync(
    "openssl",
    [
      "req",
      "-x509",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:P-256",
      "-nodes",
      "-keyout",
      "/dev/null",
      "-days",
      "1",
      "-subj",
      subject
    ],
    {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"]
    }
  )

const signing = (pem: string) =>
  resolveDevelopmentSigningArguments(async (_command, args) =>
    args[0] === "find-identity" ? identities : pem
  )

describe("resolveDevelopmentSigningArguments", () => {
  it("falls back to ad-hoc signing without an Apple Development identity", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {})
    expect(
      await resolveDevelopmentSigningArguments(async () => "0 valid identities found")
    ).toEqual([])
  })

  it("signs with the identity's team, or ad hoc when the certificate has none", async () => {
    vi.spyOn(console, "log").mockImplementation(() => {})
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {})

    expect(
      await signing(certificate("/CN=Apple Development: Test Person (ABCDE12345)/OU=TEAM123456"))
    ).toEqual([
      "CODE_SIGN_IDENTITY=0123456789ABCDEF0123456789ABCDEF01234567",
      "DEVELOPMENT_TEAM=TEAM123456",
      "CODE_SIGN_STYLE=Manual",
      "PROVISIONING_PROFILE_SPECIFIER="
    ])
    expect(await signing(certificate("/CN=Apple Development: Test Person (ABCDE12345)"))).toEqual(
      []
    )
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("no signing team identifier"))
  })
})

describe("terminateExactDevelopmentApp", () => {
  it("stops only the process whose whole command is the app executable", async () => {
    const directory = await scratch()
    const executable = join(directory, "Codevisor (test)")
    await symlink(process.execPath, executable)
    const keepAlive = ["-e", "setTimeout(() => {}, 60000)"]
    const exact = running(spawn(executable, keepAlive))
    const unrelated = running(spawn(process.execPath, keepAlive))
    await new Promise((resolve) => setTimeout(resolve, 200))

    terminateExactDevelopmentApp(`${executable} ${keepAlive.join(" ")}`)
    terminateExactDevelopmentApp(join(directory, "missing"))

    expect((await waitForExit(exact)).signal).toBe("SIGTERM")
    expect(unrelated.exitCode).toBeNull()
  })
})

describe("cloud dev", () => {
  it("uses an explicit free cloud port and passes non-dev variables to wrangler", async () => {
    const repoRoot = await scratch()
    await mkdir(join(repoRoot, "apps/cloud"), { recursive: true })
    await writeFile(
      join(repoRoot, "apps/cloud/.dev.vars"),
      '# comment\nSECRET="value"\nCODEVISOR_DEV_SKIP=1\nbroken\n'
    )

    const cloud = await resolveCloudDevInstance({
      environment: { CODEVISOR_DEV_CLOUD_PORT: "47123" },
      instanceHash: "abcdef1234",
      layout: developmentLayout(repoRoot, {}),
      repoRoot
    })

    expect(cloud).toEqual({
      cloudExtraVariables: ["--var", "SECRET:value"],
      cloudPersistPath: join(repoRoot, "tmp/.wrangler"),
      cloudPort: 47123,
      cloudUrl: "http://localhost:47123"
    })
    expect(cloudWranglerEnvironment({ A: "1" }).WRANGLER_BUILD_CONDITIONS).toContain(
      "@codevisor/source"
    )
  })

  it("refuses an explicit cloud port that's taken", async () => {
    const port = await listen(() => {}, "0.0.0.0")
    await expect(
      resolveCloudDevInstance({
        environment: { CODEVISOR_DEV_CLOUD_PORT: String(port) },
        instanceHash: "abcdef1234",
        layout: developmentLayout("/repo", {}),
        repoRoot: "/repo"
      })
    ).rejects.toThrow(/already in use/)
  })

  it("hands the dev login token to the app once the cloud is healthy", async () => {
    const port = await listen((request, response) => {
      response.setHeader("content-type", "application/json")
      response.end(request.url === "/dev/login" ? JSON.stringify({ token: "dev-token" }) : "{}")
    })
    const sharedEnvironment: Record<string, string | undefined> = {}
    const cloudProcess = running(spawn("/bin/sleep", ["60"]))

    await prepareCloudSession({
      cloudProcess,
      cloudUrl: `http://127.0.0.1:${port}`,
      sharedEnvironment
    })

    expect(sharedEnvironment.CODEVISOR_DEV_CLOUD_TOKEN).toBe("dev-token")
  })

  it("continues without a session when the cloud exits or login fails", async () => {
    const exited = spawn(process.execPath, ["-e", ""])
    await waitForExit(exited)
    const sharedEnvironment: Record<string, string | undefined> = {}
    await prepareCloudSession({
      cloudProcess: exited,
      cloudUrl: "http://127.0.0.1:1",
      sharedEnvironment
    })

    const port = await listen((request, response) => {
      response.statusCode = request.url === "/health" ? 200 : 500
      response.end()
    })
    await prepareCloudSession({
      cloudProcess: running(spawn("/bin/sleep", ["60"])),
      cloudUrl: `http://127.0.0.1:${port}`,
      sharedEnvironment
    })

    expect(sharedEnvironment.CODEVISOR_DEV_CLOUD_TOKEN).toBeUndefined()
  })

  it("applies local migrations and logs instead of failing", async () => {
    const calls: Array<Array<string>> = []
    await applyCloudDevMigrations({
      cloudPersistPath: "/persist",
      repoRoot: "/repo",
      run: async (command, args, cwd) => {
        calls.push([command, ...args, `cwd=${cwd}`])
        throw new Error("no wrangler")
      }
    })

    expect(calls[0]).toEqual([
      "bun",
      "x",
      "wrangler",
      "d1",
      "migrations",
      "apply",
      "codevisor-cloud",
      "--local",
      "--persist-to",
      "/persist",
      "cwd=/repo/apps/cloud"
    ])
  })
})
