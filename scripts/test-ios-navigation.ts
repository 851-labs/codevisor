import { realpath } from "node:fs/promises"
// Real swipe and long-press gestures against the production sidebar, with an
// in-memory fleet fixture. No server or user account is required.
import { fileURLToPath } from "node:url"

import { bootstrapDevelopment } from "./dev-bootstrap.ts"
import { iosDevelopmentBundleIdentifier } from "./dev-layout.ts"
import { requireIOSSimulator } from "./ios-simulator-state.ts"
import { runXcodebuild } from "./xcodebuild.ts"

const root = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const simulator = await requireIOSSimulator(root)
console.log(`  device:    ${simulator.name} (${simulator.runtime}) ${simulator.udid}`)
await bootstrapDevelopment(root)
await runXcodebuild(root, "ios", [
  "-project",
  "apps/ios/Codevisor.xcodeproj",
  "-scheme",
  "Codevisor",
  "-configuration",
  "Debug",
  "-destination",
  `platform=iOS Simulator,id=${simulator.udid}`,
  `CODEVISOR_IOS_BUNDLE_IDENTIFIER=${iosDevelopmentBundleIdentifier(root)}`,
  "-only-testing:NavigationTests",
  ...process.argv.slice(2),
  "test"
])
