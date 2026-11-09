import { ensureChromium } from "./chromium-artifact.ts"
import { runCommand } from "./commands.ts"
import { ensureGhosttyFramework } from "./ghostty-artifact.ts"
import { ensureSwiftFramework } from "./net-artifact.ts"

type Environment = Readonly<Record<string, string | undefined>>

export interface BootstrapOptions {
  readonly environment?: Environment
  readonly ghostty?: boolean
  readonly ghosttyKit?: boolean
  readonly architectures?: ReadonlyArray<string> | undefined
}

export async function bootstrapDevelopment(
  repoRoot: string,
  options: BootstrapOptions = {}
): Promise<void> {
  console.log("\n$ bun install --frozen-lockfile")
  await runCommand("bun", ["install", "--frozen-lockfile"], {
    cwd: repoRoot,
    env: options.environment ?? process.env
  })
  await ensureSwiftFramework(repoRoot, options.environment)
  if (options.ghostty === true) await ensureNativeFrameworks(repoRoot, options)
  else if (options.ghosttyKit === true) await ensureGhosttyFramework(repoRoot, options.environment)
}

export async function ensureNativeFrameworks(
  repoRoot: string,
  options: BootstrapOptions = {}
): Promise<void> {
  await ensureGhosttyFramework(repoRoot, options.environment)
  await ensureChromium(repoRoot, options.environment, options.architectures)
}
