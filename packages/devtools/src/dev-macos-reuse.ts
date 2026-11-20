import { join } from "node:path"

export interface ReusableMacOSApp {
  readonly appBundle: string
  readonly bundleIdentifier: string
  readonly executableName: string
  readonly capture: (command: string, args: Array<string>) => Promise<string>
  readonly run: (command: string, args: Array<string>) => Promise<unknown>
}

export async function verifyReusableMacOSApp(app: ReusableMacOSApp): Promise<void> {
  const plist = join(app.appBundle, "Contents", "Info.plist")
  const metadata = JSON.parse(
    await app.capture("/usr/bin/plutil", ["-convert", "json", "-o", "-", plist])
  )
  for (const [key, expected] of [
    ["CFBundleIdentifier", app.bundleIdentifier],
    ["CFBundleExecutable", app.executableName]
  ] as const) {
    const actual = metadata[key]
    if (actual !== expected)
      throw new Error(`Cannot reuse macOS build: ${key} is ${actual}, expected ${expected}.`)
  }
  await app.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.appBundle])
}
