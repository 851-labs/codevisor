import { realpath } from "node:fs/promises"
import { join } from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"

import { bootstrapDevelopment } from "./dev-bootstrap.mjs"
import {
  developmentLayout,
  ensureBuildDirectories,
  IOS_DEVELOPMENT_BUNDLE_IDENTIFIER,
  localDevelopmentEnvironment
} from "./dev-layout.mjs"
import { runXcodebuild } from "./xcodebuild.mjs"

const repoRoot = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const target = process.argv[2]
const forwardedArguments = process.argv.slice(3)
const layout = developmentLayout(repoRoot)
await ensureBuildDirectories(layout)
const environment = localDevelopmentEnvironment(layout)

if (target === "macos") {
  await bootstrapDevelopment(repoRoot, { environment, ghostty: true })
  await runXcodebuild(
    repoRoot,
    "macos",
    [
      "-project",
      "apps/macos/Codevisor.xcodeproj",
      "-scheme",
      "Codevisor",
      "-configuration",
      "Debug",
      "CODEVISOR_DEV_PRODUCT_NAME=Codevisor",
      "CODEVISOR_DEV_DISPLAY_NAME=Codevisor",
      "CODE_SIGNING_ALLOWED=NO",
      ...forwardedArguments,
      "build"
    ],
    { environment, layout }
  )
  console.log(
    `\nBuilt macOS app: ${join(layout.build.macos.derivedData, "Build/Products/Debug/Codevisor.app")}`
  )
} else if (target === "ios") {
  await bootstrapDevelopment(repoRoot, { environment })
  await runXcodebuild(
    repoRoot,
    "ios",
    [
      "-project",
      "apps/ios/Codevisor.xcodeproj",
      "-scheme",
      "Codevisor",
      "-configuration",
      "Debug",
      "-destination",
      "generic/platform=iOS Simulator",
      `CODEVISOR_IOS_BUNDLE_IDENTIFIER=${IOS_DEVELOPMENT_BUNDLE_IDENTIFIER}`,
      ...forwardedArguments,
      "build"
    ],
    { environment, layout }
  )
  console.log(
    `\nBuilt iOS simulator app: ${join(layout.build.ios.derivedData, "Build/Products/Debug-iphonesimulator/Codevisor.app")}`
  )
} else if (target === "list:macos") {
  await bootstrapDevelopment(repoRoot, { environment })
  await runXcodebuild(
    repoRoot,
    "macos",
    ["-list", "-project", "apps/macos/Codevisor.xcodeproj", ...forwardedArguments],
    { environment, layout }
  )
} else {
  console.error("usage: bun scripts/build-native.mjs <macos|ios|list:macos> [xcodebuild arguments]")
  process.exitCode = 2
}
