import { existsSync, readFileSync, readdirSync, rmSync } from "node:fs"
import { createRequire } from "node:module"
import { dirname, join } from "node:path"
import { spawn, spawnSync, type ChildProcess } from "node:child_process"
import { CdpConnection, delay } from "./browser-cdp.js"

export const systemChromePath = (): string | undefined => {
  const taskHome = process.env.HOME
  const candidates =
    process.platform === "darwin"
      ? [
          "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
          ...(taskHome === undefined
            ? []
            : [join(taskHome, "Applications/Google Chrome.app/Contents/MacOS/Google Chrome")])
        ]
      : process.platform === "linux"
        ? [
            "/usr/bin/google-chrome-stable",
            "/usr/bin/google-chrome",
            "/usr/bin/chromium-browser",
            "/usr/bin/chromium",
            "/snap/bin/chromium"
          ]
        : []
  return candidates.find(existsSync)
}

export const downloadedChromiumPath = (browsersDir: string): string | undefined => {
  if (!existsSync(browsersDir)) return undefined
  const roots = readdirSync(browsersDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.startsWith("chromium-"))
    .map((entry) => join(browsersDir, entry.name))
    .sort()
    .reverse()
  for (const root of roots) {
    const candidates =
      process.platform === "darwin"
        ? [
            join(
              root,
              "chrome-mac-arm64",
              "Google Chrome for Testing.app",
              "Contents",
              "MacOS",
              "Google Chrome for Testing"
            ),
            join(
              root,
              "chrome-mac-x64",
              "Google Chrome for Testing.app",
              "Contents",
              "MacOS",
              "Google Chrome for Testing"
            ),
            join(root, "chrome-mac", "Chromium.app", "Contents", "MacOS", "Chromium")
          ]
        : process.platform === "linux"
          ? [join(root, "chrome-linux64", "chrome"), join(root, "chrome-linux", "chrome")]
          : []
    const executable = candidates.find(existsSync)
    if (executable !== undefined) return executable
  }
  return undefined
}

export const runBrowserInstaller = async (browsersDir: string): Promise<void> => {
  const require = createRequire(import.meta.url)
  const packageJson = require.resolve("playwright/package.json")
  const cli = join(dirname(packageJson), "cli.js")
  await new Promise<void>((resolve, reject) => {
    const child = spawn(process.execPath, [cli, "install", "chromium", "--no-shell"], {
      env: { ...process.env, PLAYWRIGHT_BROWSERS_PATH: browsersDir },
      stdio: ["ignore", "inherit", "inherit"]
    })
    child.once("error", reject)
    child.once("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`Chromium installer exited with ${code}`))
    )
  })
}

const devToolsEndpoint = (profileDir: string): string | undefined => {
  const file = join(profileDir, "DevToolsActivePort")
  if (!existsSync(file)) return undefined
  const [port, path] = readFileSync(file, "utf8").trim().split(/\r?\n/)
  return port !== undefined && path !== undefined ? `ws://127.0.0.1:${port}${path}` : undefined
}

const connectExistingProfile = async (profileDir: string): Promise<CdpConnection | undefined> => {
  const endpoint = devToolsEndpoint(profileDir)
  if (endpoint === undefined) return undefined
  return CdpConnection.connect(endpoint).catch(() => undefined)
}

export interface ManagedBrowserLaunchEnvironment {
  readonly platform: NodeJS.Platform
  readonly uid: number | undefined
  readonly containerized: boolean
}

export const managedBrowserSandboxArguments = (
  environment: ManagedBrowserLaunchEnvironment
): ReadonlyArray<string> =>
  environment.platform === "linux" && (environment.uid === 0 || environment.containerized)
    ? ["--no-sandbox"]
    : []

const linuxContainerRuntime = (): boolean => {
  if (process.platform !== "linux") return false
  if (process.env.CODEVISOR_BROWSER_NO_SANDBOX === "1") return true
  if (existsSync("/.dockerenv") || existsSync("/run/.containerenv")) return true
  const indicators: ReadonlyArray<readonly [string, RegExp]> = [
    ["/proc/1/cgroup", /(?:docker|containerd|kubepods|podman|lxc)/i],
    ["/proc/cmdline", /(?:^|\s)init=\/sbin\/vminitd(?:\s|$)/]
  ]
  return indicators.some(([path, pattern]) => {
    try {
      return pattern.test(readFileSync(path, "utf8"))
    } catch {
      return false
    }
  })
}

export const launchManagedBrowser = async (
  executablePath: string,
  profileDir: string
): Promise<{ connection: CdpConnection; processHandle?: ChildProcess }> => {
  const existing = await connectExistingProfile(profileDir)
  if (existing !== undefined) return { connection: existing }
  rmSync(join(profileDir, "DevToolsActivePort"), { force: true })
  const processHandle = spawn(
    executablePath,
    [
      `--user-data-dir=${profileDir}`,
      "--remote-debugging-port=0",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-background-networking",
      ...managedBrowserSandboxArguments({
        platform: process.platform,
        uid: process.getuid?.(),
        containerized: linuxContainerRuntime()
      }),
      ...(process.env.CODEVISOR_BROWSER_HEADLESS === "1" ? ["--headless=new"] : []),
      "about:blank"
    ],
    { stdio: "ignore" }
  )
  let launchError: Error | undefined
  processHandle.once("error", (cause) => {
    launchError = cause
  })
  const deadline = Date.now() + 30_000
  while (Date.now() < deadline) {
    if (launchError !== undefined) throw launchError
    if (processHandle.exitCode !== null) {
      throw new Error(`Chromium exited during startup with ${processHandle.exitCode}`)
    }
    const endpoint = devToolsEndpoint(profileDir)
    if (endpoint !== undefined) {
      try {
        return { connection: await CdpConnection.connect(endpoint), processHandle }
      } catch {
        // DevToolsActivePort can appear one event-loop turn before the socket accepts.
      }
    }
    await delay(100)
  }
  processHandle.kill("SIGTERM")
  throw new Error("Timed out waiting for Chromium's debugging endpoint")
}

export const userChromiumIsRunning = (): boolean => {
  if (process.env.CODEVISOR_BROWSER_CDP_URL !== undefined) return true
  if (process.platform !== "darwin" && process.platform !== "linux") return false
  const names =
    process.platform === "darwin"
      ? ["Google Chrome", "Chromium", "Brave Browser", "Microsoft Edge"]
      : ["google-chrome", "chromium", "chromium-browser", "brave-browser", "microsoft-edge"]
  return names.some((name) => spawnSync("pgrep", ["-x", name], { stdio: "ignore" }).status === 0)
}
