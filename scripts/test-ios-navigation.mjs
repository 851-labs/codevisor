// Real swipe and long-press gestures against the production sidebar, with an
// in-memory fleet fixture. No server or user account is required.
import { fileURLToPath } from "node:url"
import { realpath } from "node:fs/promises"
import { bootstrapDevelopment } from "./dev-bootstrap.mjs"
import { requestedIOSSimulatorName, selectIOSSimulator } from "./dev-ios-target.mjs"
import { iosDevelopmentBundleIdentifier } from "./dev-layout.mjs"
import { runXcodebuild } from "./xcodebuild.mjs"

const root = await realpath(fileURLToPath(new URL("..", import.meta.url)))
await bootstrapDevelopment(root)
const simulator = await selectIOSSimulator(root, requestedIOSSimulatorName())
console.log(`  device:    ${simulator.name} (${simulator.runtime}) ${simulator.udid}`)
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
