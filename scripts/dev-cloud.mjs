import { spawn } from "node:child_process"
import { join } from "node:path"
import process from "node:process"

import { readCloudDevVariables } from "./dev-host-tools.mjs"
import { delay, findAvailablePort, isPortAvailable, parsePort } from "./dev-shared.mjs"

/// The cloud dev instance (apps/cloud on `wrangler dev`): auth + relay hub,
/// running fully locally with DEV_AUTH enabled and state under tmp/.

// Like the server and www ports, the cloud's preferred port is stable for
// this worktree and it scans its own range when that port is occupied. Pin
// CODEVISOR_DEV_CLOUD_PORT only when testing real GitHub OAuth — OAuth apps
// allow exactly one callback URL, so it must match the registered
// http://localhost:<port>/api/auth/callback/github exactly.
// Optional cloud dev vars live in apps/cloud/.dev.vars — gitignored, created
// once in the MAIN clone. Worktrees read the main clone's copy automatically;
// a worktree-local .dev.vars takes precedence. See .dev.vars.example.
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
      // Keys prefixed CODEVISOR_DEV_ configure this script, not the Worker.
      .filter(([key]) => !key.startsWith("CODEVISOR_DEV_"))
      .flatMap(([key, value]) => ["--var", `${key}:${value}`]),
    cloudPersistPath: layout.wrangler,
    cloudPort,
    cloudUrl: `http://localhost:${cloudPort}`
  }
}

// cwd apps/cloud so bunx resolves the workspace's wrangler version — a
// stray/global wrangler brings its own (older) workerd, which cannot read
// local D1/DO state written by the workspace version. Failures fall through
// to prepareCloudSession's "continuing without it" path instead of crashing.
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

/// Real Workers runtime (workerd) with local D1 and Durable Objects,
/// persisted under tmp/ like all other dev state.
export function spawnCloudDev({ cloud, containerized, repoRoot, worktreeName }) {
  return spawn(
    "bun",
    [
      "x",
      "wrangler",
      "dev",
      // Containers reach the hub through the host gateway, which needs a
      // non-loopback bind. Same-host mode keeps the loopback default.
      ...(containerized ? ["--ip", "0.0.0.0"] : []),
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
    { cwd: join(repoRoot, "apps/cloud"), env: process.env, stdio: "inherit" }
  )
}

// Wait for the cloud Worker, sign in as the dev user, and hand the session
// token to the app (Settings → Account works with zero GitHub OAuth setup).
// Non-fatal throughout: local dev must keep working when the cloud piece is
// broken or slow — it's additive, never required.
export async function prepareCloudSession({ cloudProcess, cloudUrl, sharedEnvironment }) {
  try {
    for (let attempt = 0; attempt < 120; attempt += 1) {
      if (cloudProcess.exitCode !== null) return
      try {
        const health = await fetch(`${cloudUrl}/health`)
        if (health.ok) break
      } catch {
        // wrangler is still starting.
      }
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
      `Cloud dev instance unavailable (${error instanceof Error ? error.message : error}); continuing without it.`
    )
  }
}
