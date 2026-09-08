import { cp, mkdir } from "node:fs/promises"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import { chromiumHelperName, chromiumHelperSuffixes, run } from "./chromium-artifact.mjs"

const root = fileURLToPath(new URL("..", import.meta.url))
const env = process.env
const frameworks = join(env.TARGET_BUILD_DIR, env.FRAMEWORKS_FOLDER_PATH)
const icon = join(
  env.TARGET_BUILD_DIR,
  env.UNLOCALIZED_RESOURCES_FOLDER_PATH,
  `${env.ASSETCATALOG_COMPILER_APPICON_NAME}.icns`
)

// Run after the Resources phase: a clean build must use this build's compiled
// icon, including the generated worktree color. Seal it inside every helper.
for (const suffix of chromiumHelperSuffixes) {
  const bundle = join(frameworks, `${chromiumHelperName(env.PRODUCT_NAME)}${suffix}.app`)
  const resources = join(bundle, "Contents/Resources")
  await mkdir(resources, { recursive: true })
  await cp(icon, join(resources, "AppIcon.icns"))
  await run(
    "codesign",
    [
      "--force",
      "--sign",
      env.EXPANDED_CODE_SIGN_IDENTITY || "-",
      "--options",
      "runtime",
      "--timestamp=none",
      ...(suffix === " (Renderer)"
        ? ["--entitlements", join(root, "apps/macos/ChromiumHelper/entitlements.plist")]
        : []),
      bundle
    ],
    root
  )
}
