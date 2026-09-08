import { cp, mkdir, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises"
import { join, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { chromiumHelperName, chromiumHelperSuffixes, run } from "./chromium-artifact.mjs"

const root = resolve(fileURLToPath(new URL("..", import.meta.url)))
const env = process.env
const architectures = env.ARCHS.trim().split(/\s+/)
const frameworks = join(env.TARGET_BUILD_DIR, env.FRAMEWORKS_FOLDER_PATH)
const source = join(root, "apps/macos/Frameworks/Chromium")
const name = "Chromium Embedded Framework.framework"
const framework = join(frameworks, name)
await mkdir(frameworks, { recursive: true })
// CEF ships a flat framework. Xcode requires the standard versioned macOS
// framework layout (the same conversion used by CEF's COPY_MAC_FRAMEWORK).
await rm(framework, { recursive: true, force: true })
const versioned = join(framework, "Versions/A")
await mkdir(versioned, { recursive: true })
await run(
  "rsync",
  ["-a", join(source, architectures[0], "sdk/Release", name) + "/", versioned + "/"],
  root
)
await symlink("A", join(framework, "Versions/Current"))
for (const item of ["Chromium Embedded Framework", "Libraries", "Resources"]) {
  await symlink(`Versions/Current/${item}`, join(framework, item))
}

async function* files(directory, relative = "") {
  for (const entry of await readdir(join(directory, relative), { withFileTypes: true })) {
    const path = join(relative, entry.name)
    if (entry.isDirectory()) yield* files(directory, path)
    else if (entry.isFile()) yield path
  }
}
const binaries = []
for await (const path of files(framework)) {
  // The framework layout is versioned; only visit actual files, never symlinks.
  if (path.endsWith("Chromium Embedded Framework") || path.endsWith(".dylib")) binaries.push(path)
}
if (architectures.length > 1) {
  for (const path of binaries) {
    await run(
      "lipo",
      [
        "-create",
        ...architectures.map((arch) =>
          join(source, arch, "sdk/Release", name, path.replace(/^Versions\/A\//, ""))
        ),
        "-output",
        join(framework, path)
      ],
      root
    )
  }
  for (const arch of architectures.slice(1)) {
    await cp(
      join(source, arch, "sdk/Release", name, `Resources/v8_context_snapshot.${arch}.bin`),
      join(framework, `Resources/v8_context_snapshot.${arch}.bin`)
    )
  }
}
const signing = env.EXPANDED_CODE_SIGN_IDENTITY || "-"
for (const path of binaries)
  await run(
    "codesign",
    [
      "--force",
      "--sign",
      signing,
      "--options",
      "runtime",
      "--timestamp=none",
      join(framework, path)
    ],
    root
  )
await run(
  "codesign",
  ["--force", "--sign", signing, "--options", "runtime", "--timestamp=none", framework],
  root
)
for (const suffix of chromiumHelperSuffixes) {
  const helperName = `${chromiumHelperName(env.PRODUCT_NAME)}${suffix}`
  // Chromium derives each specialized bundle path from the base executable
  // name, so the bundle and executable names must include the same dev suffix.
  const bundle = join(frameworks, `${helperName}.app`)
  // Recreate known helper bundles so renamed executables and old signatures
  // cannot survive an incremental build or a switch between app variants.
  await rm(join(frameworks, `Codevisor Helper${suffix}.app`), { recursive: true, force: true })
  await rm(bundle, { recursive: true, force: true })
  const contents = join(bundle, "Contents")
  await mkdir(join(contents, "MacOS"), { recursive: true })
  const executable = join(contents, "MacOS", helperName)
  if (architectures.length === 1)
    await cp(join(source, architectures[0], "Codevisor Helper"), executable)
  else
    await run(
      "lipo",
      [
        "-create",
        ...architectures.map((arch) => join(source, arch, "Codevisor Helper")),
        "-output",
        executable
      ],
      root
    )
  const identifier = `${env.PRODUCT_BUNDLE_IDENTIFIER}.chromium.helper${suffix ? "." + suffix.slice(2, -1).toLowerCase() : ""}`
  const strings = {
    CFBundleExecutable: helperName,
    CFBundleName: helperName,
    CFBundleDisplayName: helperName,
    CFBundleIconFile: "AppIcon.icns",
    CFBundleIdentifier: identifier,
    CFBundlePackageType: "APPL",
    CFBundleVersion: "1",
    CFBundleShortVersionString: "1.0",
    LSMinimumSystemVersion: "12.0"
  }
  await writeFile(
    join(contents, "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>${Object.entries(
      strings
    )
      .map(
        ([key, value]) =>
          `<key>${key}</key><string>${value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")}</string>`
      )
      .join(
        ""
      )}<key>LSUIElement</key><true/><key>LSEnvironment</key><dict><key>MallocNanoZone</key><string>0</string></dict></dict></plist>`
  )
  // The final build phase copies the compiled app icon and signs the helpers.
}
const resources = join(env.TARGET_BUILD_DIR, env.UNLOCALIZED_RESOURCES_FOLDER_PATH)
await mkdir(resources, { recursive: true })
// Resolve frontend assets from the exact DevTools resource pack in this CEF SDK.
// GRIT converts resource paths to uppercase identifiers with punctuation replaced
// by underscores. Keep the map generated so a CEF update cannot mix frontend versions.
const resourceHeader = await readFile(
  join(source, architectures[0], "sdk/include/cef_pack_resources.h"),
  "utf8"
)
const devToolsSection = resourceHeader
  .split("// From devtools_resources.h:")[1]
  ?.split("// From ")[0]
if (!devToolsSection) throw new Error("CEF SDK is missing its DevTools resource index")
const devToolsResources = Object.fromEntries(
  [...devToolsSection.matchAll(/^#define (\w+) (\d+)$/gm)].map(([, name, id]) => [name, Number(id)])
)
if (!devToolsResources.ENTRYPOINTS_DEVTOOLS_APP_DEVTOOLS_APP_JS)
  throw new Error("CEF SDK is missing the inspector frontend")
await writeFile(
  join(resources, "Chromium-DevTools-resources.json"),
  JSON.stringify(devToolsResources)
)
await cp(
  join(root, "apps/macos/ChromiumHelper/devtools.js"),
  join(resources, "Chromium-DevTools.js")
)
for (const [sourceName, targetName] of [
  ["LICENSE.txt", "Chromium-LICENSE.txt"],
  ["CREDITS.html", "Chromium-CREDITS.html"]
]) {
  await rm(join(frameworks, targetName), { force: true })
  await cp(join(source, architectures[0], "sdk", sourceName), join(resources, targetName))
}
