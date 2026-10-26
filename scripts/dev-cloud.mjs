import { spawn } from "node:child_process"
import { join } from "node:path"
import process from "node:process"

import { readCloudDevVariables } from "./dev-host-tools.mjs"
import { delay, findAvailablePort, isPortAvailable, parsePort } from "./dev-shared.mjs"

export const CLOUD_WRANGLER_BUILD_CONDITIONS = "@codevisor/source,workerd,worker,browser"

export function cloudWranglerEnvironment(environment = process.env) {
  return { ...environment, WRANGLER_BUILD_CONDITIONS: CLOUD_WRANGLER_BUILD_CONDITIONS }
}

export async function resolveCloudDevInstance({ environment, instanceHash, layout, repoRoot }) {
  const cloudDevVariables = await readCloudDevVariables(repoRoot)
  const preferredCloudPort = 41_000 + (Number.parseInt(instanceHash.slice(0, 8), 16) % 10_000)
  const requestedCloudPort = parsePort(
    environment.CODEVISOR_DEV_CLOUD_PORT,
    "CODEVISOR_DEV_CLOUD_PORT"
  )
  if (requestedCloudPort !== undefined && !(await isPortAvailable(requestedCloudPort))) {
    throw new Error(
      `CODEVISOR_DEV_CLOUD_PORT ${requestedCloudPort} is already in use; ` +
        "stop its owner or choose a different explicit port."
    )
  }
  const cloudPort =
    requestedCloudPort ?? (await findAvailablePort(preferredCloudPort, 41_000, 10_000))
  return {
    cloudExtraVariables: Object.entries(cloudDevVariables)
      .filter(([key]) => !key.startsWith("CODEVISOR_DEV_"))
      .flatMap(([key, value]) => ["--var", `${key}:${value}`]),
    cloudPersistPath: layout.wrangler,
    cloudPort,
    cloudUrl: `http://localhost:${cloudPort}`
  }
}

export async function applyCloudDevMigrations({ cloudPersistPath, repoRoot, run }) {
  await run(
    "bun",
    [
      "x",
      "wrangler",
      "d1",
      "migrations",
      "apply",
      "codevisor-cloud",
      "--local",
      "--persist-to",
      cloudPersistPath
    ],
    join(repoRoot, "apps/cloud")
  ).catch((error) => {
    console.error(`Cloud dev migrations failed (${error instanceof Error ? error.message : error})`)
  })
}

export function spawnCloudDev({ cloud, listensBeyondLoopback, repoRoot, worktreeName }) {
  return spawn(
    "bun",
    [
      "x",
      "wrangler",
      "dev",
      ...(listensBeyondLoopback ? ["--ip", "0.0.0.0"] : []),
      "--port",
      String(cloud.cloudPort),
      "--persist-to",
      cloud.cloudPersistPath,
      "--var",
      "DEV_AUTH:1",
      "--var",
      `PUBLIC_BASE_URL:${cloud.cloudUrl}`,
      "--var",
      `INSTANCE_NAME:Codevisor Cloud (${worktreeName})`,
      ...cloud.cloudExtraVariables,
      "--show-interactive-dev-session=false"
    ],
    { cwd: join(repoRoot, "apps/cloud"), env: cloudWranglerEnvironment(), stdio: "inherit" }
  )
}

export async function prepareCloudSession({ cloudProcess, cloudUrl, sharedEnvironment }) {
  try {
    for (let attempt = 0; attempt < 120; attempt += 1) {
      if (cloudProcess.exitCode !== null) return
      try {
        const health = await fetch(`${cloudUrl}/health`)
        if (health.ok) break
      } catch {}
      await delay(250)
    }
    const response = await fetch(`${cloudUrl}/dev/login`, { method: "POST" })
    if (!response.ok) throw new Error(`dev login returned ${response.status}`)
    const { token } = await response.json()
    sharedEnvironment.CODEVISOR_DEV_CLOUD_TOKEN = token
    console.log("")
    console.log(`Cloud dev instance ready at ${cloudUrl}`)
    console.log(`  Dev account session handed to the app — sign in via "Use Development Account".`)
    console.log(`  Device approvals: ${cloudUrl}/device`)
    console.log("")
  } catch (error) {
    console.error(
      `Cloud dev instance unavailable (${error instanceof Error ? error.message : String(error)}); continuing without it.`
    )
  }
}
