import { join } from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"

import {
  buildGhosttyFramework,
  ensureGhosttyFramework,
  ghosttyArtifactsRoot,
  ghosttyBuildStamp,
  ghosttyCachedFramework,
  validFramework
} from "../packages/devtools/src/ghostty-artifact.ts"

const repoRoot = fileURLToPath(new URL("..", import.meta.url))
const [command = "ensure", framework] = process.argv.slice(2)

try {
  if (command === "ensure") console.log((await ensureGhosttyFramework(repoRoot)).cachedFramework)
  else if (command === "build") console.log((await buildGhosttyFramework(repoRoot)).cachedFramework)
  else if (command === "validate") {
    const path = framework ?? join(repoRoot, "apps/macos/Frameworks/GhosttyKit.xcframework")
    const stamp = await ghosttyBuildStamp(repoRoot)
    if (!(await validFramework(path, stamp))) {
      throw new Error(
        `${path} is not GhosttyKit ${stamp} (missing, stale, or incomplete); run apps/macos/scripts/build-ghostty.sh`
      )
    }
  } else if (command === "print-path") {
    console.log(ghosttyCachedFramework(ghosttyArtifactsRoot(), await ghosttyBuildStamp(repoRoot)))
  } else {
    throw new Error(`Unknown command ${command}; expected ensure, build, validate, or print-path`)
  }
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
}
