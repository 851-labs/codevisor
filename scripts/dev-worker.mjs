import { spawn } from "node:child_process"
import { realpath, rm } from "node:fs/promises"
import { join } from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"

import { parseDevelopmentRunnerArguments } from "./dev-arguments.mjs"
import { bootstrapDevelopment, ensureNativeFrameworks } from "./dev-bootstrap.mjs"
import {
  applyCloudDevMigrations,
  prepareCloudSession,
  resolveCloudDevInstance,
  spawnCloudDev
} from "./dev-cloud.mjs"
import {
  launchDevRemoteServer,
  prepareDevContainers,
  resolveContainerEngine
} from "./dev-containers.mjs"
import {
  createDevelopmentAppIcon,
  createDevelopmentBrowserExtensionIcons,
  makeCommandRunner,
  resolveDevelopmentSigningArguments,
  terminateExactDevelopmentApp
} from "./dev-host-tools.mjs"
import {
  migrateLegacyDevelopmentState,
  resolveDevelopmentInstance,
  sanitizeAmbientEnvironment
} from "./dev-instance.mjs"
import {
  buildIOSDevelopmentApp,
  launchIOSDevelopmentApp,
  terminateIOSDevelopmentApp
} from "./dev-ios-target.mjs"
import {
  ensureDevelopmentDirectories,
  localDevelopmentEnvironment,
  remoteDevelopmentEnvironment
} from "./dev-layout.mjs"
import { requestsMacOSBuildReuse, verifyReusableMacOSApp } from "./dev-macos-reuse.mjs"
import { devNetCloudVariables, devNetEnvironment, launchDevNet, prepareDevNet } from "./dev-net.mjs"
import { describeExit, shutdownDevServers, waitForExit, waitForHealth } from "./dev-shared.mjs"
import { requireIOSSimulator } from "./ios-simulator-state.mjs"
import { runXcodebuild } from "./xcodebuild.mjs"

const repoRoot = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const cliArguments = process.argv.slice(2)
const { wantsContainers, containerEnginePreference } = parseDevelopmentRunnerArguments(
  cliArguments,
  {
    allowedArguments: ["--no-ios", "--reuse-macos-build"]
  }
)
const reuseMacOSBuild = requestsMacOSBuildReuse(cliArguments)
const includesIOS = !cliArguments.includes("--no-ios")
let simulator
if (includesIOS) simulator = await requireIOSSimulator(repoRoot)
sanitizeAmbientEnvironment(process.env)
const instance = await resolveDevelopmentInstance(repoRoot, process.env)
const {
  appBundle,
  appExecutable,
  appName,
  appServerName,
  cloudRemoteName,
  cloudRemotePort,
  dataDirectory,
  derivedDataPath,
  developmentIconColor,
  iOSBundleIdentifier,
  instanceHash,
  instanceName,
  layout,
  macOSBundleIdentifier,
  port,
  urlScheme,
  worktreeName,
  worktreesDirectory,
  wwwPort
} = instance
const { capture, run } = makeCommandRunner(repoRoot)
if (reuseMacOSBuild) {
  await verifyReusableMacOSApp({
    appBundle,
    bundleIdentifier: macOSBundleIdentifier,
    executableName: appName,
    capture,
    run
  })
}
const { cloudExtraVariables, cloudPersistPath, cloudPort, cloudUrl } =
  await resolveCloudDevInstance({
    environment: process.env,
    instanceHash,
    layout,
    repoRoot
  })
await migrateLegacyDevelopmentState(instance, repoRoot)

await ensureDevelopmentDirectories(layout)
Object.assign(process.env, localDevelopmentEnvironment(layout, process.env))

console.log(`Codevisor development instance: ${worktreeName}`)
console.log(`  app:      ${appName}`)
console.log(`  server:   http://127.0.0.1:${port}`)
console.log(`  www:      http://localhost:${wwwPort}`)
console.log(`  viacloud: http://127.0.0.1:${cloudRemotePort}  (${cloudRemoteName})`)
console.log(`  cloud:    ${cloudUrl}`)
console.log(`  data:     ${dataDirectory}`)
console.log(`  worktrees:${worktreesDirectory}`)
console.log(`  icon:     ${developmentIconColor.hex}`)
if (includesIOS) console.log(`  targets:  macOS + iOS (${simulator.name})`)

await bootstrapDevelopment(repoRoot, { environment: process.env })
const macOSProject = ["-project", "apps/macos/Codevisor.xcodeproj", "-scheme", "Codevisor"]
const prepareServers = async () => {
  await run("bun", ["run", "--cwd", "apps/server", "build"])
  await applyCloudDevMigrations({ cloudPersistPath, repoRoot, run })
  let containerEngine
  if (wantsContainers) containerEngine = await resolveContainerEngine(containerEnginePreference)
  if (wantsContainers && containerEngine === undefined) {
    console.warn("No usable container engine; the dev remote runs as a same-host process.")
  }
  if (containerEngine === undefined) return undefined
  return prepareDevContainers({
    repoRoot,
    containerRoot: join(layout.tmpRoot, "container"),
    engine: containerEngine,
    worktreeHash: instanceHash
  })
}
const [containerContext] = await Promise.all([
  prepareServers(),
  ensureNativeFrameworks(repoRoot, { environment: process.env }),
  reuseMacOSBuild
    ? undefined
    : runXcodebuild(repoRoot, "macos", [...macOSProject, "-resolvePackageDependencies"], {
        environment: process.env,
        layout
      })
])

const net = await prepareDevNet({
  instanceHash,
  netRoot: join(layout.tmpRoot, "net"),
  containerContext
})
const cloud = spawnCloudDev({
  cloud: {
    cloudExtraVariables: [...cloudExtraVariables, ...devNetCloudVariables(net)],
    cloudPersistPath,
    cloudPort,
    cloudUrl
  },
  containerized: containerContext !== undefined,
  repoRoot,
  worktreeName
})

if (!reuseMacOSBuild) {
  const generatedIconDirectory = await createDevelopmentAppIcon(repoRoot, developmentIconColor)
  const developmentSigningArguments = await resolveDevelopmentSigningArguments(capture)
  try {
    await runXcodebuild(
      repoRoot,
      "macos",
      [
        ...macOSProject,
        "-configuration",
        "Debug",
        `CODEVISOR_DEV_PRODUCT_NAME=${appName}`,
        `CODEVISOR_DEV_DISPLAY_NAME=${appName}`,
        `CODEVISOR_DEV_BUNDLE_IDENTIFIER=${macOSBundleIdentifier}`,
        `CODEVISOR_URL_SCHEME=${urlScheme}`,
        "CODEVISOR_APP_ICON_NAME=AppIconDevGenerated",
        "INFOPLIST_KEY_CFBundleIconFile=AppIconDevGenerated",
        "INFOPLIST_KEY_CFBundleIconName=AppIconDevGenerated",
        ...developmentSigningArguments,
        "build"
      ],
      { environment: process.env, layout }
    )
  } finally {
    await rm(generatedIconDirectory, { recursive: true, force: true })
  }
} else {
  console.log("Reusing the existing signed macOS app; native source changes are not built.")
}
let iosTarget
if (includesIOS) {
  iosTarget = await buildIOSDevelopmentApp({
    repoRoot,
    layout,
    appDisplayName: appName,
    bundleIdentifier: iOSBundleIdentifier,
    urlScheme,
    developmentIconColor,
    environment: process.env
  })
}
const relays = await launchDevNet({
  net,
  repoRoot,
  cloudPort,
  containerized: containerContext !== undefined
})
const developmentBrowserIconDirectory = await createDevelopmentBrowserExtensionIcons({
  appName,
  derivedDataPath,
  layout,
  run
})

const sharedEnvironment = {
  ...localDevelopmentEnvironment(layout, process.env),
  CODEVISOR_DEV_WORKTREE: worktreeName,
  CODEVISOR_DEV_INSTANCE_ID: instanceName,
  CODEVISOR_DEV_ICON_COLOR: developmentIconColor.hex,
  CODEVISOR_DEV_EXTENSION_ICON_DIR: developmentBrowserIconDirectory,
  CODEVISOR_DEV_PORT: String(port),
  CODEVISOR_DEV_WWW_PORT: String(wwwPort),
  CODEVISOR_DEV_CLOUD_URL: cloudUrl,
  VITE_CODEVISOR_DEV_CLOUD_URL: cloudUrl,
  CODEVISOR_DEV_URL_SCHEME: urlScheme,
  VITE_CODEVISOR_DEV_URL_SCHEME: urlScheme,
  CODEVISOR_DEV_CLOUD_TOKEN: "",
  ...(await devNetEnvironment(net))
}
const withoutCloudToken = (environment) => {
  const copy = { ...environment }
  delete copy.CODEVISOR_DEV_CLOUD_TOKEN
  return copy
}
const databasePath = join(dataDirectory, "codevisor-server.sqlite")
const upgradeStatusPath = join(dataDirectory, "data-upgrade.json")
await prepareCloudSession({ cloudProcess: cloud, cloudUrl, sharedEnvironment })

const server = spawn(
  "node",
  [
    join(repoRoot, "apps/server/dist/main.js"),
    "serve",
    "--host",
    "0.0.0.0",
    "--port",
    String(port),
    "--db",
    databasePath,
    "--auth",
    "token",
    "--kind",
    "local",
    "--name",
    appServerName,
    "--upgrade-status",
    upgradeStatusPath
  ],
  { cwd: repoRoot, env: withoutCloudToken(sharedEnvironment), stdio: "inherit" }
)

const www = spawn(
  "bun",
  ["run", "--cwd", "apps/www", "dev", "--port", String(wwwPort), "--strictPort"],
  { cwd: repoRoot, env: sharedEnvironment, stdio: "inherit" }
)

const cloudRemoteServer = await launchDevRemoteServer({
  containerContext,
  repoRoot,
  remoteRootHost: join(layout.tmpRoot, "remote-cloud"),
  serverRoots: layout.remoteCloud,
  port: cloudRemotePort,
  serverName: cloudRemoteName,
  directPath: "disabled",
  environment: {
    ...remoteDevelopmentEnvironment(layout, process.env),
    CODEVISOR_DEV_INSTANCE_ID: `${instanceName}-cloud`,
    CODEVISOR_DEV_CLOUD_URL: cloudUrl,
    CODEVISOR_DEV_CLOUD_TOKEN: sharedEnvironment.CODEVISOR_DEV_CLOUD_TOKEN,
    CODEVISOR_NET_PATH_POLICY: "relay-only",
    ...(await devNetEnvironment(net, { inline: true }))
  }
})

let app
let stopping = false

const stop = async (exitCode = 0) => {
  if (stopping) return
  stopping = true
  terminateExactDevelopmentApp(appExecutable)
  await terminateIOSDevelopmentApp(iosTarget)
  app?.kill("SIGTERM")
  www.kill("SIGTERM")
  cloud.kill("SIGTERM")
  for (const relay of relays) relay.kill("SIGTERM")

  await shutdownDevServers([
    [port, server],
    [cloudRemotePort, cloudRemoteServer]
  ])
  process.exitCode = exitCode
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => void stop(0))
}

const watchServerExit = (child, label) =>
  waitForExit(child).then(async (result) => {
    if (!stopping) {
      console.error(`${label} exited unexpectedly (${describeExit(result)}).`)
      await stop(result.code ?? 1)
    }
  })
const serverExit = Promise.all([
  watchServerExit(server, "Codevisor server"),
  watchServerExit(cloudRemoteServer, "Codevisor dev cloud server")
])

void waitForExit(www).then((result) => {
  if (!stopping) {
    console.error(`www dev server exited unexpectedly (${describeExit(result)}).`)
  }
})

void waitForExit(cloud).then((result) => {
  if (!stopping) {
    console.error(`cloud dev server exited unexpectedly (${describeExit(result)}).`)
  }
})

try {
  await waitForHealth(port, server)
  const remoteHealthAttempts = containerContext === undefined ? 120 : 2400
  await waitForHealth(cloudRemotePort, cloudRemoteServer, remoteHealthAttempts)
  console.log(`\n${cloudRemoteName} is ready; it appears after signing into the dev cloud.\n`)
  const launchEnvironment = Object.entries(withoutCloudToken(sharedEnvironment)).filter(
    ([key]) =>
      key === "TMPDIR" ||
      key.startsWith("CODEVISOR_") ||
      key.startsWith("HERDMAN_") ||
      key.startsWith("GHOSTTY_")
  )
  const openArguments = [
    "-n",
    "-W",
    ...launchEnvironment.flatMap(([key, value]) => ["--env", `${key}=${value}`]),
    appBundle
  ]
  app = spawn("/usr/bin/open", openArguments, {
    cwd: repoRoot,
    env: process.env,
    stdio: "inherit"
  })
  if (iosTarget !== undefined) {
    await launchIOSDevelopmentApp({
      repoRoot,
      target: iosTarget,
      environment: process.env,
      worktreeName,
      instanceName,
      developmentIconColor,
      cloudURL: cloudUrl
    })
    console.log("Press Ctrl+C to stop both apps and their shared development services.")
  }
  const result = await waitForExit(app)
  if (!stopping) await stop(result.code ?? 0)
  await serverExit
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  await stop(1)
}
